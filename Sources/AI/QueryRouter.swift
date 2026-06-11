import Foundation

/// Routes user queries: AI-powered semantic search if configured, keyword fallback otherwise.
@MainActor
final class QueryRouter: ObservableObject {
    private var aiProvider: AIProvider
    private let queryInterpreter: QueryInterpreting

    init(aiProvider: AIProvider, queryInterpreter: QueryInterpreting = QueryInterpreter()) {
        self.aiProvider = aiProvider
        self.queryInterpreter = queryInterpreter
    }

    func updateProvider(_ provider: AIProvider) {
        self.aiProvider = provider
    }

    func resolveQuerySpec(
        query: String,
        activeFilter: QueryScope = .all,
        timezone: TimeZone = .current,
        now: Date = Date()
    ) async -> QuerySpec {
        let baseSpec = queryInterpreter.parse(
            query: query,
            now: now,
            timezone: timezone,
            activeFilter: activeFilter
        )

        guard shouldUseAIPlanner(query: query, baseSpec: baseSpec) else {
            return baseSpec
        }

        do {
            let plan = try await aiProvider.planQuery(
                query: query,
                activeFilter: activeFilter,
                deterministicSpec: baseSpec
            )
            return merge(baseSpec: baseSpec, plan: plan, timezone: timezone, now: now)
        } catch {
            // Deliberate graceful degradation — but count the shape so
            // we learn when planner fallbacks spike in the field. No
            // query content leaves the device.
            PidgyTelemetry.captureAIFailure(
                provider: "router",
                model: "",
                runName: "query_planner",
                errorClass: "planner_fallback"
            )
            return baseSpec
        }
    }

    func route(
        query: String,
        querySpec: QuerySpec? = nil,
        activeFilter: QueryScope = .all,
        timezone: TimeZone = .current,
        now: Date = Date()
    ) async -> QueryIntent {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return .semanticSearch }

        let spec: QuerySpec
        if let querySpec {
            spec = querySpec
        } else {
            spec = await resolveQuerySpec(
                query: query,
                activeFilter: activeFilter,
                timezone: timezone,
                now: now
            )
        }

        switch spec.preferredEngine {
        case .messageLookup:
            return .messageSearch
        case .semanticRetrieval:
            return .semanticSearch
        case .replyTriage:
            return .agenticSearch
        case .summarize:
            return .summarySearch
        case .graphCRM:
            return .unsupported
        }
    }

    /// The planner is the only language-universal layer — keyword
    /// gating it meant the LLM never ran for non-English queries
    /// ("grampus chat me kya ho rha" has no English cue phrases), so
    /// grammar fragments did the matching. Invert the old design:
    /// skip the planner ONLY where the deterministic parser is
    /// provably sufficient — mechanical artifact lookups (wallet
    /// addresses, URLs, handles) confidently recognized by pattern.
    /// Every linguistic query gets the LLM, whatever the language.
    func shouldUseAIPlanner(query: String, baseSpec: QuerySpec) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if baseSpec.family == .exactLookup,
           baseSpec.parseConfidence >= AppConstants.AI.QueryPlanner.lowConfidenceThreshold {
            return false
        }
        return true
    }

    private func merge(
        baseSpec: QuerySpec,
        plan: QueryPlannerResultDTO,
        timezone: TimeZone,
        now: Date
    ) -> QuerySpec {
        let hints = plannerHints(from: plan)

        // Graduated trust, not an all-or-nothing cliff. Term extraction
        // (people/topics) is additive evidence and ALWAYS flows — a
        // hedging planner's {grampus} still beats raw grammar fragments.
        // REROUTING the family is the risky part: allow it when the
        // planner is absolutely confident, or clearly more confident
        // than the deterministic guess it overrides. (Live failure: the
        // plan said summary@0.62 with perfect terms; the old 0.72 cliff
        // discarded all of it in favor of a 0.45 deterministic guess.)
        let canReroute = plan.confidence >= AppConstants.AI.QueryPlanner.minimumPlannerConfidence
            || plan.confidence >= baseSpec.parseConfidence + AppConstants.AI.QueryPlanner.relativeConfidenceMargin
        guard canReroute else {
            return baseSpec.attachingPlannerHints(hints)
        }

        let resolvedFamily: QueryFamily = {
            switch plan.family.lowercased() {
            case QueryFamily.summary.rawValue:
                return .summary
            case QueryFamily.replyQueue.rawValue:
                return .replyQueue
            case QueryFamily.topicSearch.rawValue:
                return baseSpec.family
            default:
                return baseSpec.family
            }
        }()

        let resolvedScope: QueryScope = {
            switch plan.scope.lowercased() {
            case QueryScope.all.rawValue:
                return .all
            case QueryScope.dms.rawValue:
                return .dms
            case QueryScope.groups.rawValue:
                return .groups
            default:
                return baseSpec.scope
            }
        }()

        let resolvedTimeRange: TimeRangeConstraint? = {
            switch plannerTimeRangeResolution(
                token: plan.timeRange,
                timezone: timezone,
                now: now
            ) {
            case .inherit:
                return baseSpec.timeRange
            case .none:
                return nil
            case .range(let range):
                return range
            }
        }()

        return QuerySpec(
            rawQuery: baseSpec.rawQuery,
            mode: runtimeMode(for: resolvedFamily),
            family: resolvedFamily,
            preferredEngine: preferredEngine(for: resolvedFamily),
            scope: resolvedScope,
            scopeWasExplicit: baseSpec.scopeWasExplicit || resolvedScope != baseSpec.scope,
            replyConstraint: resolvedFamily == .replyQueue ? .pipelineOnMeOnly : .none,
            timeRange: resolvedTimeRange,
            parseConfidence: max(baseSpec.parseConfidence, plan.confidence),
            unsupportedFragments: baseSpec.unsupportedFragments,
            plannerHints: hints
        )
    }

    private func plannerHints(from plan: QueryPlannerResultDTO) -> QueryPlannerHints? {
        let people = normalizedPlannerTokens(plan.people)
        let topics = normalizedPlannerTokens(plan.topicTerms)
        guard !people.isEmpty || !topics.isEmpty else { return nil }
        return QueryPlannerHints(people: people, topicTerms: topics)
    }

    private func normalizedPlannerTokens(_ tokens: [String]) -> [String] {
        let normalized = tokens
            .flatMap { token in
                token
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" })
                    .map(String.init)
            }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .filter { !$0.isEmpty && $0.count >= 2 }

        return Array(NSOrderedSet(array: normalized)) as? [String] ?? normalized
    }

    private enum PlannerTimeRangeResolution {
        case inherit
        case none
        case range(TimeRangeConstraint)
    }

    private func plannerTimeRangeResolution(
        token: String,
        timezone: TimeZone,
        now: Date
    ) -> PlannerTimeRangeResolution {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        func dayRange(for date: Date, label: String) -> TimeRangeConstraint? {
            let start = calendar.startOfDay(for: date)
            guard let end = calendar.date(byAdding: .second, value: 86_399, to: start) else { return nil }
            return TimeRangeConstraint(startDate: start, endDate: end, label: label)
        }

        switch token.lowercased() {
        case "inherit":
            return .inherit
        case "none", "all_time", "all-time", "no_time_range":
            return .none
        case "today":
            guard let range = dayRange(for: now, label: "Today") else { return .inherit }
            return .range(range)
        case "yesterday":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  let range = dayRange(for: yesterday, label: "Yesterday") else { return .inherit }
            return .range(range)
        case "this_week":
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else { return .inherit }
            return .range(TimeRangeConstraint(startDate: weekInterval.start, endDate: now, label: "This Week"))
        case "last_week":
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return .inherit }
            return .range(TimeRangeConstraint(startDate: start, endDate: now, label: "Last Week"))
        case "last_30_days":
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return .inherit }
            return .range(TimeRangeConstraint(startDate: start, endDate: now, label: "Last 30 Days"))
        default:
            return .inherit
        }
    }

    private func preferredEngine(for family: QueryFamily) -> QueryEngine {
        switch family {
        case .exactLookup:
            return .messageLookup
        case .topicSearch:
            return .semanticRetrieval
        case .replyQueue:
            return .replyTriage
        case .relationship:
            return .graphCRM
        case .summary:
            return .summarize
        }
    }

    private func runtimeMode(for family: QueryFamily) -> QueryIntent {
        switch preferredEngine(for: family) {
        case .messageLookup:
            return .messageSearch
        case .semanticRetrieval:
            return .semanticSearch
        case .summarize:
            return .summarySearch
        case .replyTriage:
            return .agenticSearch
        case .graphCRM:
            return .unsupported
        }
    }
}
