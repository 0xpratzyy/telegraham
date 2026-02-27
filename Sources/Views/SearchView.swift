import SwiftUI

struct SearchView: View {
    @EnvironmentObject var telegramService: TelegramService
    @State private var query = ""
    @State private var results: [TGMessage] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @FocusState private var isSearchFocused: Bool

    private let suggestionChips = [
        "Show all groups",
        "Unread messages",
        "Search: bounty",
        "Recent DMs",
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
                        .foregroundColor(Color(white: 0.45))
                }

                TextField("Ask anything... \"Show me groups\" or \"Search: keyword\"", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.89))
                    .focused($isSearchFocused)
                    .onSubmit {
                        Task { await executeSearch() }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await executeSearch() }
                    } label: {
                        Text("Search")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.95)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.03))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(
                        isSearchFocused
                            ? Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.3)
                            : Color.white.opacity(0.06)
                    ),
                alignment: .bottom
            )

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
                                    .foregroundColor(Color(white: 0.59))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.03))
                                    .cornerRadius(16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            // Results
            if hasSearched && results.isEmpty && !isSearching {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(Color(white: 0.20))
                    Text("No results for \"\(query)\"")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.45))
                    Text("Try different keywords or a broader search")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(white: 0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)

                        ForEach(results) { message in
                            MessageCardView(message: message, highlightQuery: query)
                        }
                    }
                    .padding(8)
                }
            } else if !hasSearched {
                // Empty state with instructions
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "bolt.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.3), Color(red: 0.55, green: 0.36, blue: 0.95).opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 6) {
                        Text("Search your Telegram")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(white: 0.59))

                        Text("Type a keyword to search across all your chats")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.35))
                    }

                    Spacer()
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    private func executeSearch() async {
        let searchQuery = query.trimmingCharacters(in: .whitespaces)
        guard !searchQuery.isEmpty else { return }

        isSearching = true
        hasSearched = true
        defer { isSearching = false }

        // Extract keyword from "Search: keyword" pattern
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
