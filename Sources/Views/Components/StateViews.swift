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
