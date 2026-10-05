//
//  OnboardingCardView.swift
//  Pidgy
//
//  A quiet setup column on the existing stage. Sources, optional AI, and
//  the shortcut each have one clear place in the flow.
//

import AppKit
import SwiftUI

struct OnboardingCardView: View {
    @ObservedObject var model: OnboardingConversationModel
    @ObservedObject private var aiService: AIService
    @ObservedObject private var chatGPT = ChatGPTService.shared
    let layout: OnboardingLayout

    init(model: OnboardingConversationModel, layout: OnboardingLayout) {
        self.model = model
        self.aiService = model.aiService
        self.layout = layout
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @FocusState private var cardFocused: Bool
    @State private var keycapBounce = false
    @State private var highlighted = 0
    @State private var qrTimedOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupProgress.padding(.bottom, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.heading)
                        .font(.custom("Newsreader", size: 34).weight(.medium))
                        .tracking(-0.6)
                        .foregroundStyle(Color.white)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(model.heading)
                        .accessibilityAddTraits(.isHeader)
                        .transition(.opacity)

                    content
                        .padding(.top, 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(contentKey)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))

                    if let error = model.errorText, model.sourceDetail == nil {
                        Text(error)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(hex: 0xFF8A80))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)

            if model.step == .sources, model.sourceDetail == nil { sourceFooter.padding(.top, 12) }
            if model.step == .intelligence { intelligenceFooter.padding(.top, 12) }
            hint.padding(.top, 16)
        }
        .frame(width: layout.columnWidth, height: layout.columnHeight, alignment: .topLeading)
        .position(x: layout.center.x, y: layout.columnTop + layout.columnHeight / 2)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.88), value: contentKey)
        .animation(.easeOut(duration: 0.25), value: model.errorText)
        .onChange(of: model.panelBounceToken) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { keycapBounce = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { keycapBounce = false }
            }
        }
        .onChange(of: model.step) { _, _ in
            inputFocused = needsInput
            highlighted = model.step == .sources && model.connectedCount > 0 ? model.visibleSources.count : (model.sourceSelectionIndices.first ?? 0)
        }
        .onChange(of: model.connectedCount) { _, count in
            if count > 0 { highlighted = model.visibleSources.count }
        }
        .onChange(of: model.sourceDetail) { _, detail in
            qrTimedOut = false
            if detail == nil && model.connectedCount > 0 { highlighted = model.visibleSources.count }
        }
        .onChange(of: chatGPT.isBusy) { wasBusy, isBusy in
            if wasBusy && !isBusy && model.step == .intelligence {
                model.browserConnectionFinished?()
            }
        }
        .onAppear {
            inputFocused = needsInput
            highlighted = model.sourceSelectionIndices.last == model.visibleSources.count ? model.visibleSources.count : (model.sourceSelectionIndices.first ?? 0)
        }
        .focusable()
        .focused($cardFocused)
        .focusEffectDisabled()
        .task(id: contentKey) {
            await Task.yield()
            cardFocused = !needsInput
            inputFocused = needsInput
        }
        .onKeyPress(.escape) {
            guard !model.isBusy else { return .handled }
            if model.sourceDetail != nil { model.closeSourceDetail(); return .handled }
            guard model.canGoBack else { return .ignored }
            model.back()
            return .handled
        }
        .onKeyPress(.return) {
            guard !needsInput else { return .ignored }
            guard !model.isBusy else { return .handled }
            if model.sourceDetail != nil { return .ignored }
            if model.step == .sources, model.sourceDetail == nil {
                let rows = model.visibleSources
                if rows.indices.contains(highlighted) { model.pick(rows[highlighted]); return .handled }
            }
            model.primaryAction()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard model.step == .sources, model.sourceDetail == nil else { return .ignored }
            highlighted = model.sourceSelectionIndices.first(where: { $0 > highlighted }) ?? highlighted
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard model.step == .sources, model.sourceDetail == nil else { return .ignored }
            highlighted = model.sourceSelectionIndices.last(where: { $0 < highlighted }) ?? highlighted
            return .handled
        }
    }

    /// Drives transitions: the step, plus whether the QR is open.
    private var contentKey: String {
        "\(model.step)-\(model.sourceDetail != nil)"
    }

    private var needsInput: Bool {
        switch model.step {
        case .invite, .telegramPhone, .telegramCode, .telegramPassword, .byokKey: return true
        default: return false
        }
    }

    private var setupStage: Int {
        switch model.step {
        case .welcome, .signIn, .invite, .sources, .telegramPhone, .telegramCode, .telegramPassword: return 0
        case .intelligence, .plan, .byokKey: return 1
        case .shortcut, .launchAtLogin, .done: return 2
        }
    }

    private var setupProgress: some View {
        HStack(spacing: 10) {
            Image("PidgyLogo").resizable().scaledToFit().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Pidgy").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(model.step == .welcome ? "LET'S GET YOU SET UP" : ["1 OF 3 · SOURCES", "2 OF 3 · AI", "3 OF 3 · YOUR MAC"][setupStage])
                .font(.system(size: 10, weight: .medium)).tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.62))
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= setupStage ? OnboardingBrand.periwinkle : Color.white.opacity(0.15))
                        .frame(width: 16, height: 3)
                }
            }.accessibilityHidden(true)
        }.foregroundStyle(Color.white.opacity(0.92))
    }

    // MARK: - Content per step

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 26) {
                line("Your messages are everywhere. Bring the important bits together.")
                VStack(alignment: .leading, spacing: 20) {
                    feature("Find the exact thing", detail: "A link, a file, or something you said weeks ago.", symbol: "magnifyingglass")
                    feature("Know what needs you", detail: "See the conversations waiting for your reply.", symbol: "bubble.left.and.bubble.right")
                    feature("Keep your promises", detail: "Follow up on the things you said you would do.", symbol: "checklist")
                }
                Label("Read-only. Pidgy never sends messages or marks them as read.", systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                chips([Chip("Let's go", primary: true) { model.advanceFromWelcome() }])
            }

        case .signIn:
            if model.account.isSignedIn {
                chips([
                    Chip("Continue as \(model.account.profile?.label ?? "me")", primary: true) { model.continueWithoutAccount() },
                    Chip("Switch account", busy: model.isBusy) { model.switchAccount() }
                ])
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    line("Keep your invites and plan together. Your messages aren’t part of your Pidgy account.")
                    chips([
                        Chip("Continue with Google", glyph: .google, primary: true, busy: model.signingInProvider == .google) { model.signIn(with: .google) },
                        Chip("Continue with Apple", glyph: .apple, busy: model.signingInProvider == .apple) { model.signIn(with: .apple) },
                        Chip("Skip for now", quiet: true) { model.continueWithoutAccount() }
                    ])
                    .disabled(model.isBusy)
                }
            }

        case .invite:
            VStack(alignment: .leading, spacing: 14) {
                input(placeholder: "PIDGY-ABC123", monospaced: true, busy: model.isBusy) { model.redeemInvite() }
                #if DEBUG
                chips([Chip("Skip (debug build)", quiet: true, busy: model.isBusy) { model.debugSkipInvite() }])
                #endif
            }

        case .sources:
            if let detail = model.sourceDetail {
                qr(detail)
            } else {
                sourceList
            }

        case .telegramPhone:
            input(placeholder: "+1 555 123 4567", monospaced: true, busy: model.isBusy) { model.primaryAction() }

        case .telegramCode:
            VStack(alignment: .leading, spacing: 12) {
                line("Check Telegram on your other device, or the SMS Telegram sent you.")
                input(placeholder: "12345", monospaced: true, busy: model.isBusy) { model.primaryAction() }
                if let availableAt = model.codeResendAvailableAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(availableAt.timeIntervalSince(context.date))))
                        Button(remaining > 0 ? "Resend code in \(remaining)s" : "Resend code") { model.resendTelegramCode() }
                            .disabled(remaining > 0 || model.isBusy)
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                }
                if let status = model.statusText { line(status) }
            }

        case .telegramPassword:
            input(placeholder: "Two-step password", monospaced: false, secure: true, busy: model.isBusy) { model.primaryAction() }

        case .intelligence:
            intelligenceOptions

        case .shortcut:
            VStack(alignment: .leading, spacing: 24) {
                line("Press these keys together to open Pidgy from any app.")
                HStack(spacing: 7) { keyCap("⌘"); keyCap("⇧"); keyCap("T") }
                    .scaleEffect(keycapBounce ? 1.12 : 1)
                line("Try it now. Your conversations are always one shortcut away.")
                chips([Chip("I'll try it later", quiet: true) { model.skipShortcut() }])
            }

        case .launchAtLogin:
            VStack(alignment: .leading, spacing: 24) {
                line("Let Pidgy start when you log in so your shortcut is always ready. You can change this in Preferences.")
                chips([
                    Chip("Enable at login") { model.setLaunchAtLogin(true) },
                    Chip("Not now", primary: true) { model.setLaunchAtLogin(false) }
                ])
            }

        case .plan:
            chips([
                Chip("Pidgy AI · zero setup", primary: true) { model.choosePlan(.bundled) },
                Chip("Bring my own key") { model.choosePlan(.byok) },
                Chip("Not now", quiet: true) { model.skipPlan() }
            ])

        case .byokKey:
            VStack(alignment: .leading, spacing: 12) {
                line("Your key is stored in Keychain and sent directly to your provider.")
                chips([
                    Chip("OpenAI", selected: model.byokProvider == .openai, busy: model.isBusy) { model.setByokProvider(.openai) },
                    Chip("Claude", selected: model.byokProvider == .claude, busy: model.isBusy) { model.setByokProvider(.claude) },
                    Chip("Skip for now", quiet: true, busy: model.isBusy) { model.skipKey() }
                ])
                input(placeholder: model.byokProvider == .openai ? "sk-…" : "sk-ant-…", monospaced: true, secure: true, busy: model.isBusy) { model.verifyKey() }
            }

        case .done:
            VStack(alignment: .leading, spacing: 16) {
                feature("\(model.connectedCount) \(model.connectedCount == 1 ? "source" : "sources") connected", detail: model.connectedCount > 0 ? "Your first sync runs in the background. Results arrive as it catches up." : "Add a source in Preferences whenever you're ready.", symbol: "checkmark.circle")
                feature(model.aiService.isConfigured ? "AI is ready" : "AI can wait", detail: model.aiService.isConfigured ? "Your selected provider powers answers and summaries." : "Search works without AI. Choose a provider in Preferences later.", symbol: "sparkles")
                line("Open from the menu bar or press ⌘⇧T anytime.")
                if !model.invites.codes.isEmpty {
                      VStack(alignment: .leading, spacing: 8) {
                        line("Your invites. Each friend who joins earns you two more.")
                        HStack(spacing: 8) {
                            ForEach(model.invites.codes.prefix(3)) { InviteCodeChip(code: $0) }
                        }
                    }
                }
                chips([Chip("Open Pidgy", primary: true) { model.finish() }])
            }
        }
    }

    // MARK: - Sources

    private var intelligenceOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            line("Answers and summaries, powered by the provider you choose. You can set this up later.")
            if BundledSecrets.chatGPTLocalOSS {
                VStack(alignment: .leading, spacing: 16) {
                    feature("Your ChatGPT plan", detail: "Uses your ChatGPT allowance or credits. No API key needed.", symbol: "sparkles")
                    ChatGPTConnectionView(compact: true)
                        .buttonStyle(.bordered).controlSize(.large)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
            Button { model.beginKeySetup() } label: {
                HStack(spacing: 16) {
                    feature("Use an API key", detail: "Connect your own OpenAI or Claude account. Billed by that provider.", symbol: "key")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .padding(20)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(chatGPT.isBusy)
            if aiService.isConfigured && aiService.providerType != .chatgpt {
                Label("\(aiService.providerType.rawValue) is already configured", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(OnboardingBrand.green)
            }
            if BillingGate.showBillingUI && (BundledSecrets.hasBundledAIProxy || BundledSecrets.hasBundledOpenAIKey) {
                Button("See Pidgy AI plans") { model.exploreAIPlans() }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(OnboardingBrand.periwinkle).disabled(chatGPT.isBusy)
            }
            Label("Relevant message text is sent to the AI provider you choose. Your source connections stay read-only.", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intelligenceFooter: some View {
        HStack {
            Text("Optional · change anytime in Preferences")
                .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Chip(aiService.isConfigured ? "Continue" : "Set up later", primary: true) { model.continueFromIntelligence() }
                .disabled(chatGPT.isBusy)
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(model.sourceInstructions).padding(.bottom, 20)
            if model.visibleSources.isEmpty {
                line("No sources are available in this build. Contact Pidgy support for an updated build.")
                    .padding(.bottom, 16)
            }
            ForEach(Array(model.visibleSources.enumerated()), id: \.element.id) { i, kind in
                sourceRow(kind, highlighted: i == highlighted)
                    .onHover { if $0 { highlighted = i } }
                if i < model.visibleSources.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
            }
            privacyNote.padding(.top, 20)
        }
    }

    private var sourceFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text(model.connectedCount > 0 ? "\(model.connectedCount) connected · add more anytime" : "One connection is enough to get started")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
            Spacer()
            Chip("Continue", primary: true) { model.finishSources() }
                .disabled(model.connectedCount == 0)
                .opacity(model.connectedCount == 0 ? 0.4 : 1)
                .overlay(Capsule().strokeBorder(Color.white.opacity(highlighted == model.visibleSources.count ? 0.7 : 0), lineWidth: 2))
          }
          if model.connectedCount == 0 {
              Button("I'll connect a source later") { model.skipSources() }
                  .buttonStyle(.plain).font(.system(size: 12))
                  .foregroundStyle(Color.white.opacity(0.65))
          }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Read-only connections", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .medium))
            Text("Messages are stored on this Mac. AI features send relevant text to the AI service you choose.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .foregroundStyle(Color.white.opacity(0.72))
    }

    private func sourceRow(_ kind: OnboardingConversationModel.SourceKind, highlighted: Bool) -> some View {
        let state = model.sourceState(kind)
        return Button { model.pick(kind) } label: {
            HStack(spacing: 14) {
                sourceGlyph(kind)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                  VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Color.white)
                    if state == .unavailable {
                        Text("Unavailable in this build").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                    } else if kind == .whatsapp {
                        Text("Experimental").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7))
                    }
                    if case .failed(let message) = state {
                        Text(message).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF8A80))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                switch state {
                case .connected(let label):
                    HStack(spacing: 8) {
                        Text(label).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .trailing)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(OnboardingBrand.green).accessibilityLabel("Connected")
                    }
                case .busy(let label):
                    HStack(spacing: 8) {
                        Text(label).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.6))
                        ProgressView().controlSize(.mini)
                    }
                case .failed:
                    Text("Try again").font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xFF8A80))
                case .unavailable:
                    Image(systemName: "minus.circle").font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.35))
                case .available:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .unavailable)
        .accessibilityLabel(kind.title)
        .accessibilityValue(sourceAccessibilityValue(state))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }

    @ViewBuilder
    private func qr(_ detail: OnboardingConversationModel.SourceDetail) -> some View {
        let image: NSImage? = {
            switch detail {
            case .telegramQR(let link): return link.flatMap { WhatsAppQRCodeRenderer.image(for: $0) }
            case .whatsAppQR: return model.whatsApp.qrCode.flatMap { WhatsAppQRCodeRenderer.image(for: $0) }
            }
        }()
        let failure = qrFailure(detail)
        VStack(spacing: 16) {
            if let failure {
                  VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                    Text(failure).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Try again") {
                        qrTimedOut = false
                        model.retrySourceDetail()
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xFF8A80))
                .frame(maxWidth: .infinity)
                  .padding(20)
            } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
                if let image {
                    Image(nsImage: image).interpolation(.none).resizable().padding(10)
                } else {
                    ProgressView().controlSize(.small).preferredColorScheme(.light)
                }
            }
            .frame(width: layout.qrSide, height: layout.qrSide)
            .accessibilityLabel(image == nil ? "Preparing QR code" : "Scan this QR code with your phone")
            .task(id: image == nil) {
                guard image == nil else { return }
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                qrTimedOut = true
            }
            if image == nil { line("Preparing a secure QR code…") }
            }

            Text(detail == .whatsAppQR
                 ? "WhatsApp → Settings → Linked devices → Link a device."
                 : "Telegram → Settings → Devices → Link Desktop Device.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if detail == .whatsAppQR {
                Text("Experimental connection using an unofficial WhatsApp library. It may stop working if WhatsApp changes its service.")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
                if case .telegramQR = detail {
                    Button("Use my phone number instead") { model.usePhoneInstead() }
                }
                Button("Back to sources") { model.closeSourceDetail() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .onChange(of: image != nil) { _, ready in
            if ready { qrTimedOut = false }
        }
    }

    @ViewBuilder
    private func sourceGlyph(_ kind: OnboardingConversationModel.SourceKind) -> some View {
        switch kind {
        case .telegram: BrandSVGGlyph(name: "TelegramGlyph", size: 22)
        case .slack: ZStack { Color.white; BrandSVGGlyph(name: "SlackGlyph", inset: 2, size: 22) }
        case .gmail: ZStack { Color.white; BrandSVGGlyph(name: "GmailGlyph", inset: 2, size: 22) }
        case .whatsapp:
            ZStack {
                Color(hex: 0x25D366)
                BrandSVGGlyph(name: "WhatsAppGlyph", inset: 3, size: 22)
            }
        }
    }

    // MARK: - Pieces

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                .foregroundStyle(OnboardingBrand.periwinkle).frame(width: 24).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.94))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.62))
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chips(_ items: [Chip]) -> some View {
        GlassEffectContainer(spacing: 14) {
            FlowLayout(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, chip in chip.rise(i) }
            }
        }
    }

    private func input(placeholder: String, monospaced: Bool, secure: Bool = false, busy: Bool, submit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Group {
                if secure { SecureField(placeholder, text: $model.inputText) } else { TextField(placeholder, text: $model.inputText) }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 17, design: .monospaced) : .system(size: 17))
            .foregroundStyle(Color.white)
            .focused($inputFocused)
            .onSubmit { if model.canSubmitInput { submit() } }
            .accessibilityLabel(inputLabel)
            .disabled(busy)

            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: submit) {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.inputText.isEmpty ? Color.white.opacity(0.35) : Color.black.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(model.inputText.isEmpty ? Color.white.opacity(0.12) : Color.white))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSubmitInput)
                .accessibilityLabel("Continue")
                .help("Continue")
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(inputFocused ? 0.4 : 0.15)).frame(height: 1)
        }
        .frame(maxWidth: 380)
        .animation(.easeOut(duration: 0.15), value: inputFocused)
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(minWidth: 40, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
    }

    private var inputLabel: String {
        switch model.step {
        case .invite: return "Invite code"
        case .telegramPhone: return "Phone number including country code"
        case .telegramCode: return "Telegram verification code"
        case .telegramPassword: return "Telegram two-step password"
        case .byokKey: return "\(model.byokProvider.rawValue) API key"
        default: return "Your response"
        }
    }

    private func sourceAccessibilityValue(_ state: OnboardingConversationModel.SourceState) -> String {
        switch state {
        case .available: return "Not connected"
        case .connected(let name): return "Connected, \(name)"
        case .busy(let label): return label
        case .failed(let message): return "Connection failed. \(message). Try again."
        case .unavailable: return "Unavailable"
        }
    }

    private func qrFailure(_ detail: OnboardingConversationModel.SourceDetail) -> String? {
        if detail == .whatsAppQR {
            switch model.sourceState(.whatsapp) {
            case .failed(let message): return message
            case .unavailable: return "WhatsApp isn’t available in this build."
            default: break
            }
        } else if let error = model.errorText { return error }
        return qrTimedOut ? "The QR code couldn’t load. Check your connection and try again." : nil
    }

    private var hint: some View {
        HStack(spacing: 14) {
            if model.canGoBack || model.sourceDetail != nil {
                Button {
                    if model.sourceDetail != nil { model.closeSourceDetail() } else { model.back() }
                } label: { Label("Back", systemImage: "arrow.left") }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("Back (Esc)")
            }
            Spacer()
            if model.step == .sources, model.sourceDetail == nil {
                Text("↑↓ Choose · ↵ \(highlighted == model.visibleSources.count && model.connectedCount > 0 ? "Continue" : "Connect")")
            } else if model.sourceDetail == nil {
                Text("↵ Continue")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.72))
    }

}

// MARK: - Chip

struct Chip: View, Identifiable {
    enum Glyph { case google, apple }

    let id = UUID()
    let title: String
    var glyph: Glyph? = nil
    var primary = false
    var quiet = false
    var selected = false
    var busy = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, glyph: Glyph? = nil, primary: Bool = false, quiet: Bool = false, selected: Bool = false, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.glyph = glyph
        self.primary = primary
        self.quiet = quiet
        self.selected = selected
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let glyph {
                    switch glyph {
                    case .apple: Image(systemName: "apple.logo").font(.system(size: 13, weight: .medium))
                    case .google: Text("G").font(.system(size: 13, weight: .bold))
                    }
                }
                Text(title).font(.system(size: 14, weight: quiet ? .regular : .medium))
                if busy { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(primary ? Color.black.opacity(0.88) : (quiet ? Color.white.opacity(hovering ? 0.9 : 0.65) : Color.white))
            .padding(.horizontal, quiet ? 12 : 18)
            .padding(.vertical, 11)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ChipSurface(primary: primary, glass: glass))
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(quiet ? 0 : (hovering ? 0.35 : 0.16)), lineWidth: 1)
        )
        .scaleEffect(hovering && !busy && !reduceMotion ? 1.03 : 1)
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }

    private var glass: Glass {
        if primary { return .regular.tint(Color.white.opacity(hovering ? 0.95 : 0.85)) }
        if selected { return .regular.tint(Color.white.opacity(0.3)) }
        return .regular
    }
}

private struct ChipSurface: ViewModifier {
    let primary: Bool
    let glass: Glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if primary {
            // A tinted glass surface can still become dark on a dark desktop.
            // The primary action needs a stable light surface for its dark label.
            content.background(Color.white, in: Capsule())
        } else if reduceTransparency {
            content.background(Color(white: 0.16), in: Capsule())
        } else {
            content.glassEffect(glass, in: Capsule())
        }
    }
}

// MARK: - Rise-in

/// Staggered float-up for chips and islands.
private struct Rise: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.07 * Double(index))) { shown = true }
            }
    }
}

private extension View {
    func rise(_ index: Int) -> some View { modifier(Rise(index: index)) }
}

// MARK: - Typewriter

/// Reveals text a few characters at a time. Re-runs when the text changes.
struct TypewriterText: View {
    let text: String
    let enabled: Bool

    @State private var shown = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(text)
            .hidden()
            .overlay(alignment: .topLeading) { Text(shown) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onAppear { run() }
            .onChange(of: text) { _, _ in run() }
            .onDisappear { task?.cancel() }
    }

    private func run() {
        task?.cancel()
        guard enabled else { shown = text; return }
        shown = ""
        task = Task { @MainActor in
            var idx = text.startIndex
            while idx < text.endIndex, !Task.isCancelled {
                idx = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                shown = String(text[..<idx])
                try? await Task.sleep(for: .milliseconds(14))
            }
            if !Task.isCancelled { shown = text }
        }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
