//
//  ContextLayerInspectorView.swift
//  Pidgy — #48 context layer (review surface)
//
//  A dedicated, clearly-labeled window onto the fact store so the approach can
//  be judged keep/scrap WITHOUT disturbing the shipping Tasks/Reply surfaces:
//  the raw facts, the tasks derived from open loops, and the reply queue derived
//  from open loops — all pure views over `facts`. Opened with ⌘⇧J.
//

import SwiftUI

@MainActor
struct ContextLayerInspectorView: View {
    let telegramService: TelegramService
    let onClose: () -> Void

    @State private var openLoops: [Fact] = []
    @State private var recentFacts: [Fact] = []
    @State private var derivedTasks: [DashboardTask] = []
    @State private var derivedReplies: [FactReplyItem] = []
    @State private var stats: (total: Int, openLoops: Int, resolved: Int, chats: Int) = (0, 0, 0, 0)
    @State private var isLoading = false
    @State private var isRunningPass = false

    private var chatTitles: [Int64: String] {
        Dictionary(telegramService.visibleChats.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if isLoading && recentFacts.isEmpty {
                Spacer()
                ProgressView("Loading facts…").tint(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        statsRow
                        section("Derived tasks (open loops → tasks)", count: derivedTasks.count) {
                            if derivedTasks.isEmpty { emptyHint("No open-loop facts yet. Run a pass, or wait for the background pass.") }
                            ForEach(derivedTasks) { task in taskRow(task) }
                        }
                        section("Derived reply queue (open loops → on me / on them)", count: derivedReplies.count) {
                            if derivedReplies.isEmpty { emptyHint("Nothing owed in either direction yet.") }
                            ForEach(derivedReplies) { item in replyRow(item) }
                        }
                        section("All facts (newest first)", count: recentFacts.count) {
                            if recentFacts.isEmpty { emptyHint("The fact store is empty.") }
                            ForEach(recentFacts) { fact in factRow(fact) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(Color.Pidgy.bg2)
        .task { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Layer — #48")
                    .font(.headline)
                Text("Facts, and the tasks + reply queue derived from them. Review only — live surfaces untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await runPass() }
            } label: {
                HStack(spacing: 6) {
                    if isRunningPass { ProgressView().controlSize(.small) }
                    Text(isRunningPass ? "Running…" : "Run pass now")
                }
            }
            .disabled(isRunningPass)
            Button("Reload") { Task { await reload() } }
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statsRow: some View {
        HStack(spacing: 18) {
            stat("\(stats.total)", "facts")
            stat("\(stats.openLoops)", "open loops")
            stat("\(stats.resolved)", "resolved")
            stat("\(stats.chats)", "chats")
            if let last = FactExtractionCoordinator.shared.lastPassAt {
                stat(last.formatted(date: .omitted, time: .shortened), "last pass")
            }
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private func taskRow(_ task: DashboardTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(task.title).font(.callout.weight(.medium))
                Spacer()
                Text(task.priority.label).font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", task.confidence * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(task.personName) · \(task.chatTitle) · \(task.suggestedAction)")
                .font(.caption).foregroundStyle(.secondary)
            if !task.summary.isEmpty, task.summary != task.title {
                Text("“\(task.summary)”").font(.caption2).foregroundStyle(Color.Pidgy.fg2).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private func replyRow(_ item: FactReplyItem) -> some View {
        HStack(spacing: 10) {
            Text(item.onMe ? "ON ME" : "ON THEM")
                .font(.caption2.weight(.bold))
                .foregroundStyle(item.onMe ? Color.Pidgy.warning : Color.Pidgy.accent)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.action).font(.callout)
                Text("\(item.person) · \(item.chatTitle)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private func factRow(_ fact: Fact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(fact.subjectEntity).font(.caption.weight(.semibold))
                Text("—\(fact.predicate.rawValue)→").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(fact.objectText).font(.caption)
                Spacer()
                Text(fact.isOpen ? "OPEN" : "RESOLVED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(fact.isOpen ? Color.Pidgy.accent : Color.Pidgy.fg2)
            }
            HStack(spacing: 8) {
                Text(chatTitles[fact.sourceChatId] ?? "Chat \(fact.sourceChatId)")
                Text("·")
                Text(fact.validFrom.formatted(date: .abbreviated, time: .omitted))
                if !fact.sourceText.isEmpty {
                    Text("· “\(fact.sourceText)”").lineLimit(1)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(fact.isOpen ? 0.04 : 0.015)))
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            content()
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).italic()
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let titles = chatTitles
        async let loops = DatabaseManager.shared.loadOpenFacts(predicates: FactPredicate.openLoops, limit: 500)
        async let recent = DatabaseManager.shared.loadRecentFacts(limit: 400)
        async let s = DatabaseManager.shared.factStoreStats()
        let (loopFacts, recentList, statTuple) = await (loops, recent, s)
        openLoops = loopFacts
        recentFacts = recentList
        stats = statTuple
        derivedTasks = FactProjection.tasks(from: loopFacts, chatTitles: titles)
        derivedReplies = FactProjection.replyQueue(from: loopFacts, chatTitles: titles)
    }

    private func runPass() async {
        isRunningPass = true
        await FactExtractionCoordinator.shared.runPassNow()
        await reload()
        isRunningPass = false
    }
}

/// Adds the inspector sheet + the ⌘⇧J hidden hotkey in one modifier, so the
/// host view's body stays small enough for the type-checker.
struct ContextInspectorPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let telegramService: TelegramService

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                ContextLayerInspectorView(
                    telegramService: telegramService,
                    onClose: { isPresented = false }
                )
                .preferredColorScheme(.dark)
                .presentationBackground(Color.Pidgy.bg2)
            }
            .background {
                if ContextLayer.enabled {
                    Button { isPresented = true } label: { EmptyView() }
                        .buttonStyle(.plain)
                        .keyboardShortcut("j", modifiers: [.command, .shift])
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
