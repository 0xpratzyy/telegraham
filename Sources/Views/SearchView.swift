import SwiftUI

struct SearchView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var query = ""
    @State private var results: [TGMessage] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var currentIntent: QueryIntent?
    @FocusState private var isSearchFocused: Bool

    private let suggestionChips = [
        "Show all groups",
        "Who needs a reply?",
        "Weekly digest",
        "Unread DMs",
        "Search: keyword",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }

                TextField("Ask anything... \"Show me groups\" or \"Search: keyword\"", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
                    .onSubmit {
                        Task { await executeSearch() }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                        currentIntent = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await executeSearch() }
                    } label: {
                        Text("Search")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(
                        isSearchFocused
                            ? Color.accentColor.opacity(0.3)
                            : Color.secondary.opacity(0.1)
                    ),
                alignment: .bottom
            )

            // AI banner when not configured
            if !aiService.isConfigured && !hasSearched {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                    Text("Add an AI API key in Settings for smart summaries and priorities")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.05))
            }

            // Suggestion chips (visible when search is empty)
            if query.isEmpty && !hasSearched {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestionChips, id: \.self) { chip in
                            Button {
                                query = chip
                                Task { await executeSearch() }
                            } label: {
                                Text(chip)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            // Results area — switches based on intent
            if hasSearched {
                switch currentIntent {
                case .groupDiscovery:
                    GroupDiscoveryView()

                case .dmIntelligence:
                    DMIntelligenceView()

                case .actionItems:
                    ActionItemsView()

                case .digest:
                    DigestView()

                case .messageSearch, .none:
                    messageSearchResults
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "bolt.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.3), Color.purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 6) {
                        Text("Search your Telegram")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text("Type a keyword or ask a question")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Message Search Results

    @ViewBuilder
    private var messageSearchResults: some View {
        if results.isEmpty && !isSearching {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text("No results for \"\(query)\"")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Try different keywords or a broader search")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !results.isEmpty {
            ScrollView {
                LazyVStack(spacing: 6) {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    ForEach(results) { message in
                        MessageCardView(message: message, highlightQuery: query)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Search Execution

    private func executeSearch() async {
        let searchQuery = query.trimmingCharacters(in: .whitespaces)
        guard !searchQuery.isEmpty else { return }

        isSearching = true
        hasSearched = true
        defer { isSearching = false }

        // Route the query
        let intent = await aiService.queryRouter.route(query: searchQuery)
        currentIntent = intent

        // Only perform keyword search for messageSearch intent
        if intent == .messageSearch {
            let keyword: String
            if searchQuery.lowercased().hasPrefix("search:") {
                keyword = String(searchQuery.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else {
                keyword = searchQuery
            }

            do {
                results = try await telegramService.searchMessages(query: keyword)
            } catch {
                print("[Search] Error: \(error)")
                results = []
            }
        }
    }
}
