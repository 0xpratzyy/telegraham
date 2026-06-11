import SwiftUI

// MARK: - PidgyFeedbackSheet
//
// SwiftUI port of the `FeedbackSheet.jsx` design prototype. Presented
// as a native macOS NSSheet (`.sheet(isPresented:)`) attached to the
// dashboard window — so it actually drops from the titlebar without
// us having to fake the scrim + chrome ourselves.
//
// Inside the sheet:
//   • Kind selector (Bug / Idea / Other) as a segmented control.
//   • Free-text area, 132pt min, 2000-char cap, char counter, with
//     a kind-aware placeholder.
//   • Optional email for follow-up.
//   • Auto-attached metadata panel — Version + commit SHA, OS,
//     current view (the dashboard page the user was on).
//   • Footer: privacy hint + Cancel + Send.
//
// Wired to `PidgyTelemetry.submitFeedback` which dispatches to Sentry
// as a SentryFeedback event (filterable in the feedback inbox by the
// `feedback.kind` tag). When Sentry isn't configured (source builds /
// beta without DSN) the call is a silent no-op — UI still shows the
// success toast so the user's flow doesn't break.
//
// Keyboard:
//   • Esc closes the sheet (default macOS sheet behaviour).
//   • ⌘↩ submits if the textarea has at least 5 non-whitespace chars.

struct PidgyFeedbackSheet: View {
    let currentViewLabel: String
    let userFirstName: String?
    let onClose: () -> Void

    /// `attachmentText` carries the launcher's "Flag answer" context
    /// (query + answer + shown results). It renders as a visible,
    /// removable attachment panel — the text area stays free for the
    /// user's own "what was wrong" note. Nil for the normal feedback
    /// path.
    let attachmentText: String?

    init(
        currentViewLabel: String,
        userFirstName: String?,
        attachmentText: String? = nil,
        onClose: @escaping () -> Void
    ) {
        self.currentViewLabel = currentViewLabel
        self.userFirstName = userFirstName
        self.attachmentText = attachmentText
        self.onClose = onClose
    }

    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bug: return "Bug"
            case .idea: return "Idea"
            case .other: return "Other"
            }
        }
        var placeholder: String {
            switch self {
            case .bug:
                return "What were you trying to do, and what happened instead?"
            case .idea:
                return "What would make Pidgy more useful for you?"
            case .other:
                return "Tell us anything — we read every note."
            }
        }
    }

    private enum FocusField { case text, email }

    private static let maxLen = 2000
    private static let minLen = 5

    @State private var kind: Kind = .bug
    @State private var text: String = ""
    @State private var email: String = ""
    @State private var isSubmitting = false
    @State private var didJustSubmit = false
    @State private var includeAttachment = true
    @FocusState private var focus: FocusField?

    private var canSubmit: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minLen
            && !isSubmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodySection
            footer
        }
        .frame(width: 540)
        .background(Color.Pidgy.bg2)
        .onAppear {
            // NSSheets focus their primary input on open — matching
            // that here so the user can just start typing.
            DispatchQueue.main.async { focus = .text }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send feedback")
                    .font(.system(size: 22, weight: .medium))
                    .tracking(-0.4)
                    .foregroundStyle(Color.Pidgy.fg1)
                Text("Goes straight to the Pidgy team. We read every one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    // MARK: - Body

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            kindSelector
            textArea
            if attachmentText != nil, includeAttachment {
                attachmentPanel
            }
            emailField
            metadataPanel
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    /// The flagged-answer context, shown as a removable attachment.
    /// Everything in it is visible and scrollable — what you see here
    /// is exactly what's appended to your note on Send; hit Remove and
    /// none of it leaves the machine.
    private var attachmentPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flag")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg3)
                Text("Flagged answer — attached")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg2)
                Spacer(minLength: 0)
                Button {
                    includeAttachment = false
                } label: {
                    Text("Remove")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                .buttonStyle(.plain)
                .help("Send your note without the flagged answer context")
            }
            ScrollView {
                Text(attachmentText ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.Pidgy.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            Text("Sent together with your note. Hit Remove if you'd rather not share it.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.Pidgy.fg4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.Pidgy.bg1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.Pidgy.border1)
                )
        )
    }

    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("KIND", trailing: nil)
            HStack(spacing: 4) {
                ForEach(Kind.allCases) { k in
                    KindSegment(
                        kind: k,
                        isSelected: kind == k,
                        action: { kind = k }
                    )
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.Pidgy.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.Pidgy.border1)
                    )
            )
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(
                "WHAT'S ON YOUR MIND?",
                trailing: "\(text.count) / \(Self.maxLen)"
            )
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($focus, equals: .text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 132)
                    .onChange(of: text) { _, new in
                        if new.count > Self.maxLen {
                            text = String(new.prefix(Self.maxLen))
                        }
                    }
                if text.isEmpty {
                    Text(attachmentText != nil ? "What was wrong with this answer?" : kind.placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.Pidgy.bg1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        focus == .text ? Color.Pidgy.accentFg : Color.Pidgy.border2,
                        lineWidth: 1
                    )
            )
        }
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("EMAIL")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.84)
                    .foregroundStyle(Color.Pidgy.fg3)
                Text("· optional")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Pidgy.fg4)
                Spacer()
                Text("So we can follow up")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
            TextField("you@example.com", text: $email)
                .focused($focus, equals: .email)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.Pidgy.bg1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            focus == .email ? Color.Pidgy.accentFg : Color.Pidgy.border2,
                            lineWidth: 1
                        )
                )
        }
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg3)
                Text("Attached automatically")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg2)
            }
            metaRow(key: "VERSION", value: "Pidgy \(Self.appVersion) · \(Self.commitSHA)", isMono: true)
            metaRow(key: "SYSTEM", value: Self.osVersion, isMono: true)
            metaRow(key: "VIEW", value: currentViewLabel, isMono: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.Pidgy.bg1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.Pidgy.border1)
                )
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                // With a flagged answer attached, chat content IS being
                // shared (visibly, above) — the privacy line must say so.
                Text(
                    attachmentText != nil && includeAttachment
                        ? "Only your note and the attachment above are sent."
                        : "No message content or contacts are sent."
                )
                .font(.system(size: 11.5))
            }
            .foregroundStyle(Color.Pidgy.fg4)
            Spacer(minLength: 0)
            Button("Cancel") {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.Pidgy.fg1)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.Pidgy.border3)
            )
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                    }
                    Text(isSubmitting ? "Sending…" : "Send feedback")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(canSubmit ? Color.white : Color.Pidgy.fg4)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(canSubmit ? Color.Pidgy.accent : Color.Pidgy.bg3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(canSubmit ? Color.Pidgy.accent : Color.Pidgy.border2)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.Pidgy.border1)
                .frame(height: 1)
        }
    }

    // MARK: - Submit

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true

        // The flagged-answer attachment travels in the message body so
        // it lands where feedback is read — but only if the user kept
        // it (the attachment panel has a Remove button).
        var message = text
        if let attachmentText, includeAttachment {
            message += "\n\n— Flagged answer context —\n\(attachmentText)"
        }

        PidgyTelemetry.submitFeedback(
            message: message,
            kind: kind.rawValue,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : email.trimmingCharacters(in: .whitespacesAndNewlines),
            name: userFirstName,
            extras: [
                "view": currentViewLabel,
                "version": Self.appVersion,
                "commit": Self.commitSHA,
                "os": Self.osVersion
            ]
        )

        // Brief delay so the user actually sees the spinner; matches
        // the JSX prototype's 520ms artificial pause. Closes on its
        // own — `onClose` triggers the sheet to dismiss.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 520_000_000)
            isSubmitting = false
            didJustSubmit = true
            onClose()
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.84)
                .foregroundStyle(Color.Pidgy.fg3)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
        }
    }

    private func metaRow(key: String, value: String, isMono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.Pidgy.fg4)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: isMono ? .monospaced : .default))
                .foregroundStyle(Color.Pidgy.fg2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Static metadata

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private static var commitSHA: String {
        // Single source of truth — BundledSecrets reads from the
        // build-stamped sidecar file with an Info.plist fallback.
        BundledSecrets.buildCommitSHA
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - Kind segment button

private struct KindSegment: View {
    let kind: PidgyFeedbackSheet.Kind
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(kind.label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(foregroundColor)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.Pidgy.bg3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var foregroundColor: Color {
        if isSelected { return Color.Pidgy.fg1 }
        return isHovering ? Color.Pidgy.fg2 : Color.Pidgy.fg3
    }
}

// MARK: - View-label helper

extension DashboardPage {
    /// Human-readable label sent with feedback as the "current view"
    /// context — matches the JSX's viewLabels map.
    var feedbackLabel: String {
        switch self {
        case .dashboard: return "Dashboard › What to do now"
        case .replyQueue: return "Reply queue"
        case .tasks: return "Tasks"
        case .people: return "People"
        case .topics: return "Topics"
        case .preferences: return "Settings"
        }
    }
}
