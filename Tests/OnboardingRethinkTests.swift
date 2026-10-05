import AppKit
import SwiftUI
import XCTest
@testable import Pidgy

@MainActor
final class OnboardingRethinkTests: XCTestCase {
    private func makeModel() -> OnboardingConversationModel {
        OnboardingConversationModel(
            telegramService: TelegramService(),
            aiService: AIService(testingProvider: NoAIProvider(), isConfigured: false),
            pigeon: PigeonActor(), observeServices: false, onFinished: {}
        )
    }

    func testDeferringSourcesAndAIKeepsSetupOpenAndDoesNotConnectAnything() {
        let model = makeModel()
        model.configurePreview(step: .sources)
        model.skipSources()
        XCTAssertEqual(model.step, .intelligence)
        XCTAssertTrue(model.picked.isEmpty)
        XCTAssertFalse(model.aiService.isConfigured)
        model.primaryAction()
        XCTAssertEqual(model.step, .shortcut)
        model.back()
        XCTAssertEqual(model.step, .intelligence)
        model.back()
        XCTAssertEqual(model.step, .sources)
    }

    func testAPIKeyBranchReturnsToAIChoiceAndClearsSensitiveInput() {
        let model = makeModel()
        model.configurePreview(step: .intelligence)
        model.beginKeySetup()
        XCTAssertEqual(model.step, .byokKey)
        model.inputText = "synthetic-private-key"
        model.back()
        XCTAssertEqual(model.step, .intelligence)
        XCTAssertTrue(model.inputText.isEmpty)
        model.beginKeySetup()
        model.skipKey()
        XCTAssertEqual(model.step, .intelligence)
        XCTAssertFalse(model.aiService.isConfigured)
    }

    func testUnavailableSourcesRemainDiscoverableButCannotBeSelected() {
        let model = makeModel()
        model.configurePreview(step: .sources, sources: [.telegram: .available, .whatsapp: .available])
        XCTAssertEqual(model.visibleSources, [.telegram, .slack, .gmail, .whatsapp])
        XCTAssertEqual(model.sourceSelectionIndices, [0, 3])
        model.pick(.gmail)
        model.pick(.slack)
        XCTAssertTrue(model.picked.isEmpty)
        XCTAssertNil(model.sourceDetail)
    }

    func testCompletedSetupCanOpenWithoutTelegramCredentials() {
        XCTAssertTrue(OnboardingRouting.canOpenDashboard(didComplete: true, hasTelegramCredentials: false))
        XCTAssertTrue(OnboardingRouting.canOpenDashboard(didComplete: true, hasTelegramCredentials: true))
        XCTAssertFalse(OnboardingRouting.canOpenDashboard(didComplete: false, hasTelegramCredentials: false))
    }

    func testConfiguredAIIsNotSentBackToBillingChoice() {
        let model = makeModel()
        model.aiService.isConfigured = true
        model.configurePreview(step: .launchAtLogin)
        model.primaryAction()
        XCTAssertEqual(model.step, .done)
    }

    func testSkippingAIIsNotUndoneByTheLaterLoginStep() {
        XCTAssertEqual(OnboardingRouting.afterLaunchAtLogin(showBillingUI: true, aiSetupVisited: true), .done)
        let model = makeModel()
        model.configurePreview(step: .intelligence)
        model.exploreAIPlans()
        XCTAssertEqual(model.step, .plan)
        model.skipPlan()
        XCTAssertEqual(model.step, .intelligence)
        model.primaryAction()
        model.skipShortcut()
        model.primaryAction()
        XCTAssertEqual(model.step, .done)
        XCTAssertFalse(model.aiService.isConfigured)
    }

    func testRenderSetupScreensForReview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PIDGY_ONBOARDING_SNAPSHOTS"] else {
            throw XCTSkip("Set PIDGY_ONBOARDING_SNAPSHOTS to export deterministic UI review captures.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stages: [(String, OnboardingStep)] = [
            ("01-welcome", .welcome), ("02-sources", .sources), ("03-ai", .intelligence),
            ("04-shortcut", .shortcut), ("05-login", .launchAtLogin), ("06-ready", .done),
            ("07-key", .byokKey), ("08-pidgy-account", .signIn), ("09-invite", .invite),
            ("10-phone", .telegramPhone), ("11-code", .telegramCode), ("12-password", .telegramPassword)
        ]
        for size in [CGSize(width: 1000, height: 760), CGSize(width: 800, height: 600)] {
            for (name, step) in stages {
                let model = makeModel()
                model.configurePreview(step: step, sources: [.telegram: .available, .slack: .available, .gmail: .available, .whatsapp: .available])
                let view = OnboardingCardView(model: model, layout: OnboardingLayout(size: size))
                    .frame(width: size.width, height: size.height)
                    .background(Color(hex: 0x16151A))
                    .preferredColorScheme(.dark)
                    .environmentObject(model.aiService)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(650))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("\(name)-\(Int(size.width)).png"))
                window.orderOut(nil)
            }
        }
    }
}
