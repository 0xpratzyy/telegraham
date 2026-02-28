import SwiftUI

struct DigestView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var digest: DigestResult?
    @State private var selectedPeriod: DigestPeriod = .daily
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var visibleSections: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                Text("Digest")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                // Period picker
                Picker("", selection: $selectedPeriod) {
                    ForEach(DigestPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                Button {
                    Task { await generateDigest() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Content
            if isLoading {
                LoadingStateView(message: "Generating your \(selectedPeriod.rawValue.lowercased()) digest...")
            } else if let error = errorMessage {
                ErrorStateView(message: error) {
                    Task { await generateDigest() }
                }
            } else if let digestResult = digest {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        // Generated time
                        Text("Generated \(digestResult.generatedAt.formatted(Date.RelativeFormatStyle(presentation: .named)))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 4)

                        ForEach(digestResult.sections) { section in
                            digestSectionView(section)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .onAppear {
                                    withAnimation(Animation.easeIn(duration: 0.3)) {
                                        _ = visibleSections.insert(section.id)
                                    }
                                }
                                .opacity(visibleSections.contains(section.id) ? 1 : 0)
                        }
                    }
                    .padding(8)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "newspaper")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("Generate a digest of your recent Telegram activity")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Button("Generate \(selectedPeriod.rawValue) Digest") {
                        Task { await generateDigest() }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: selectedPeriod) {
            digest = nil
            visibleSections.removeAll()
        }
    }

    @ViewBuilder
    private func digestSectionView(_ section: DigestSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(section.emoji)
                    .font(.system(size: 16))
                Text(section.title)
                    .font(.system(size: 14, weight: .semibold))
            }

            TypingTextView(fullText: section.content, speed: 50)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private func generateDigest() async {
        guard aiService.isConfigured else {
            errorMessage = "Add an AI API key in Settings to generate digests"
            return
        }

        isLoading = true
        errorMessage = nil
        visibleSections.removeAll()
        defer { isLoading = false }

        do {
            let limit = selectedPeriod == .daily
                ? AppConstants.Fetch.digestDailyPerChat
                : AppConstants.Fetch.digestWeeklyPerChat
            let since = selectedPeriod == .daily
                ? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                : Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let messages = try await telegramService.getRecentMessagesForDigest(limit: limit, since: since)
            digest = try await aiService.generateDigest(messages: messages, period: selectedPeriod)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
