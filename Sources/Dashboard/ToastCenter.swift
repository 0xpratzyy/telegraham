import Combine
import Foundation
import SwiftUI

/// Tiny app-wide toast queue. A single transient message at a time,
/// shown as a floating pill at the bottom of the dashboard. Used for
/// lightweight confirmations ("Archived — remove it from Preferences")
/// where a full alert/sheet would be too heavy.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Equatable {
        let id = UUID()
        let icon: String
        let message: String

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, icon: String = "checkmark.circle", duration: TimeInterval = 3.5) {
        dismissTask?.cancel()
        let toast = Toast(icon: icon, message: message)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            current = toast
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.current == toast else { return }
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            current = nil
        }
    }
}

/// Floating toast pill. Overlay this at the bottom of a container;
/// renders nothing when there's no active toast.
struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 9) {
                    Image(systemName: toast.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.green)
                    Text(toast.message)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Button {
                        center.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule(style: .continuous)
                        .fill(PidgyDashboardTheme.raised)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(PidgyDashboardTheme.rule, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(center.current != nil)
    }
}
