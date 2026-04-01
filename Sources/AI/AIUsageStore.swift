import Foundation

actor AIUsageStore {
    static let shared = AIUsageStore()

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private let storeDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pidgy", isDirectory: true)
            .appendingPathComponent("ai_usage", isDirectory: true)
    }()

    private lazy var storeFileURL = storeDir.appendingPathComponent("daily_usage.json")
    private var recordsByID: [String: DailyAIUsageRecord] = [:]
    private var hasLoaded = false

    func record(
        provider: AIUsageProvider,
        model: String,
        requestKind: AIRequestKind,
        usage: AIProviderUsage?
    ) async {
        await loadIfNeeded()

        let dayStart = calendar.startOfDay(for: Date())
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeModel = trimmedModel.isEmpty ? "Unknown" : trimmedModel
        let id = "\(dayStart.timeIntervalSince1970)|\(provider.rawValue)|\(safeModel)|\(requestKind.rawValue)"

        var record = recordsByID[id] ?? DailyAIUsageRecord(
            dayStart: dayStart,
            provider: provider,
            model: safeModel,
            requestKind: requestKind,
            requestCount: 0,
            meteredRequestCount: 0,
            inputTokens: 0,
            outputTokens: 0
        )

        record.requestCount += 1
        if let usage {
            record.meteredRequestCount += 1
            record.inputTokens += max(0, usage.inputTokens)
            record.outputTokens += max(0, usage.outputTokens)
        }

        recordsByID[id] = record
        saveToDisk()
    }

    func loadOverview(now: Date = Date()) async -> AIUsageOverview {
        await loadIfNeeded()

        let todayStart = calendar.startOfDay(for: now)
        guard let last30Cutoff = calendar.date(byAdding: .day, value: -29, to: todayStart) else {
            return .empty
        }

        let allRecords = recordsByID.values.sorted { lhs, rhs in
            if lhs.dayStart != rhs.dayStart {
                return lhs.dayStart > rhs.dayStart
            }
            return lhs.id < rhs.id
        }

        var lifetime = AIUsageMetrics.zero
        var last30 = AIUsageMetrics.zero
        var featureMetrics: [AIRequestKind: AIUsageMetrics] = [:]
        var modelMetrics: [String: (provider: AIUsageProvider, model: String, metrics: AIUsageMetrics)] = [:]

        for record in allRecords {
            accumulate(record: record, into: &lifetime)

            guard record.dayStart >= last30Cutoff else { continue }

            accumulate(record: record, into: &last30)

            var featureTotal = featureMetrics[record.requestKind] ?? .zero
            accumulate(record: record, into: &featureTotal)
            featureMetrics[record.requestKind] = featureTotal

            let modelKey = "\(record.provider.rawValue)|\(record.model)"
            var modelTotal = modelMetrics[modelKey] ?? (record.provider, record.model, .zero)
            accumulate(record: record, into: &modelTotal.metrics)
            modelMetrics[modelKey] = modelTotal
        }

        let byFeature30Days = featureMetrics
            .map { kind, metrics in
                AIUsageBreakdownRow(
                    id: kind.rawValue,
                    title: kind.label,
                    subtitle: nil,
                    metrics: metrics
                )
            }
            .sorted(by: sortBreakdownRows)

        let byModel30Days = modelMetrics
            .values
            .map { entry in
                AIUsageBreakdownRow(
                    id: "\(entry.provider.rawValue)|\(entry.model)",
                    title: entry.model,
                    subtitle: entry.provider.label,
                    metrics: entry.metrics
                )
            }
            .sorted(by: sortBreakdownRows)

        return AIUsageOverview(
            last30Days: last30,
            lifetime: lifetime,
            byFeature30Days: byFeature30Days,
            byModel30Days: byModel30Days
        )
    }

    func invalidateAll() async {
        recordsByID.removeAll()
        hasLoaded = true
        try? FileManager.default.removeItem(at: storeDir)
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard FileManager.default.fileExists(atPath: storeFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: storeFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([DailyAIUsageRecord].self, from: data)
            recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } catch {
            recordsByID = [:]
        }
    }

    private func saveToDisk() {
        do {
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = recordsByID.values.sorted { $0.id < $1.id }
            let data = try encoder.encode(payload)
            try data.write(to: storeFileURL, options: [.atomic])
        } catch {
            // Ignore persistence failures so AI requests never fail due to local metering.
        }
    }

    private func accumulate(record: DailyAIUsageRecord, into metrics: inout AIUsageMetrics) {
        metrics.requestCount += record.requestCount
        metrics.inputTokens += record.inputTokens
        metrics.outputTokens += record.outputTokens

        let unmetered = max(0, record.requestCount - record.meteredRequestCount)
        metrics.unmeteredRequestCount += unmetered

        if let pricing = AIUsagePricingCatalog.pricing(for: record.provider, model: record.model) {
            metrics.estimatedCostUSD += pricing.estimatedCostUSD(
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens
            )
        } else {
            metrics.unpricedRequestCount += record.meteredRequestCount
        }
    }

    private func sortBreakdownRows(lhs: AIUsageBreakdownRow, rhs: AIUsageBreakdownRow) -> Bool {
        if lhs.metrics.estimatedCostUSD != rhs.metrics.estimatedCostUSD {
            return lhs.metrics.estimatedCostUSD > rhs.metrics.estimatedCostUSD
        }
        if lhs.metrics.requestCount != rhs.metrics.requestCount {
            return lhs.metrics.requestCount > rhs.metrics.requestCount
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
