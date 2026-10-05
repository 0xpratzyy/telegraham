//
//  DashboardCoachMarks.swift
//  Pidgy
//
//  Three-beat tour shown once, the first time the dashboard opens after
//  onboarding: the launcher shortcut, the reply queue, and where sources
//  live. Cards anchor to real sidebar controls via anchor preferences, so
//  they follow layout instead of hard-coded offsets.
//

import SwiftUI

enum CoachMarkTarget: Int, CaseIterable, Identifiable {
    case launcher, replyQueue, sources

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .launcher: return "Ask from anywhere"
        case .replyQueue: return "Your reply queue"
        case .sources: return "Sources and settings"
        }
    }

    var body: String {
        switch self {
        case .launcher:
            return "Press ⌘⇧T in any app to open the launcher. Ask a question, find a message, or jump to a chat."
        case .replyQueue:
            return "Messages that actually need a reply land here, ranked. Everything else stays out of the way."
        case .sources:
            return "Add Slack, Gmail, or WhatsApp later, replay this tour, or sign out — all from your account menu."
        }
    }
}

/// Bounds of the sidebar controls the coach marks point at.
struct CoachMarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachMarkTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CoachMarkTarget: Anchor<CGRect>], nextValue: () -> [CoachMarkTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tag a view as a coach-mark target.
    func coachMarkTarget(_ target: CoachMarkTarget) -> some View {
        anchorPreference(key: CoachMarkAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// Owns the "have we shown this yet" flag so the overlay can be dropped
/// into DashboardView without threading state through it.
@MainActor
final class DashboardCoachMarksModel: ObservableObject {
    @Published var isPresented: Bool
    @Published var index = 0

    init(defaults: UserDefaults = .standard) {
        let completedOnboarding = defaults.bool(forKey: AppConstants.Preferences.didCompleteOnboardingKey)
        let shown = defaults.bool(forKey: AppConstants.Preferences.didShowDashboardCoachMarksKey)
        isPresented = completedOnboarding && !shown
    }

    var target: CoachMarkTarget { CoachMarkTarget.allCases[index] }
    var isLast: Bool { index == CoachMarkTarget.allCases.count - 1 }

    func next() {
        if isLast { finish() } else { index += 1 }
    }

    func finish() {
        isPresented = false
        UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didShowDashboardCoachMarksKey)
    }
}

struct DashboardCoachMarksOverlay: View {
    @ObservedObject var model: DashboardCoachMarksModel
    let anchors: [CoachMarkTarget: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            let rect = anchors[model.target].map { proxy[$0] }
            ZStack(alignment: .topLeading) {
                // Dim everything except the target.
                Color.black.opacity(0.42)
                    .mask(
                        ZStack {
                            Rectangle()
                            if let rect {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .frame(width: rect.width + 12, height: rect.height + 10)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    )
                    .ignoresSafeArea()
                    .onTapGesture { model.next() }

                if let rect {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.Pidgy.accentFg, lineWidth: 1.5)
                        .frame(width: rect.width + 12, height: rect.height + 10)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                card
                    .frame(width: 280)
                    .offset(cardOffset(for: rect, in: proxy.size))
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.index)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.index + 1) of \(CoachMarkTarget.allCases.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Pidgy.accentFg)
                Spacer()
                Button(action: model.finish) {
                    Text("Skip")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                .buttonStyle(.plain)
            }
            Text(model.target.title)
                .font(.custom("Newsreader", size: 20).weight(.medium))
                .foregroundStyle(Color.Pidgy.fg1)
            Text(model.target.body)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Pidgy.fg2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: model.next) {
                    HStack(spacing: 6) {
                        Text(model.isLast ? "Done" : "Next")
                            .font(.system(size: 13, weight: .semibold))
                        if !model.isLast {
                            Image(systemName: "arrow.right").font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Pidgy.bg2)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.Pidgy.border3, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        )
        .id(model.index)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    /// Card sits to the right of the highlighted control, vertically
    /// centred on it and clamped inside the window.
    private func cardOffset(for rect: CGRect?, in size: CGSize) -> CGSize {
        guard let rect else {
            return CGSize(width: max(24, (size.width - 280) / 2), height: max(24, (size.height - 220) / 2))
        }
        let x = min(rect.maxX + 18, size.width - 280 - 24)
        let y = min(max(rect.midY - 80, 24), size.height - 220)
        return CGSize(width: x, height: y)
    }
}
