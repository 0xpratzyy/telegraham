import SwiftUI

/// Reusable loading state view with spinner and message.
struct LoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Rich loading state for AI search mode.
/// Shows rotating intent keywords and skeleton rows instead of a blank spinner.
struct AISearchLoadingView: View {
    let message: String
    let keywords: [String]
    var progressText: String?

    @State private var activeKeywordIndex = 0
    @State private var pulse = false

    private let timer = Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()

    private var visibleKeywords: [String] {
        guard !keywords.isEmpty else { return [] }
        if keywords.count <= 4 { return keywords }
        let start = activeKeywordIndex % keywords.count
        return (0..<4).map { keywords[(start + $0) % keywords.count] }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan.opacity(0.9))

                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()
                }

                if let progressText, !progressText.isEmpty {
                    Text(progressText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !visibleKeywords.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(visibleKeywords.enumerated()), id: \.offset) { idx, word in
                            let isActive = idx == 0
                            Text(word)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isActive ? Color.cyan.opacity(0.95) : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(isActive ? Color.cyan.opacity(0.18) : Color.secondary.opacity(0.10))
                                )
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.14),
                                Color.blue.opacity(0.07)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
            )

            VStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    AISearchSkeletonRow(
                        pulse: pulse,
                        titleWidth: index % 3 == 0 ? 220 : (index % 3 == 1 ? 180 : 250),
                        subtitleWidth: index % 2 == 0 ? 260 : 190
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(timer) { _ in
            guard !keywords.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                activeKeywordIndex = (activeKeywordIndex + 1) % keywords.count
                pulse.toggle()
            }
        }
    }
}

private struct AISearchSkeletonRow: View {
    let pulse: Bool
    let titleWidth: CGFloat
    let subtitleWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(pulse ? 0.22 : 0.14))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(pulse ? 0.24 : 0.15))
                    .frame(width: titleWidth, height: 10)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(pulse ? 0.16 : 0.10))
                    .frame(width: subtitleWidth, height: 8)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

/// Reusable error state view with icon, message, and optional retry button.
struct ErrorStateView: View {
    let message: String
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry = retryAction {
                Button("Try Again", action: retry)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Reusable empty state view with icon, title, and optional subtitle.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
