import XCTest
@testable import Pidgy

final class FlaggedAnswerFixtureTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeFixture() -> FlaggedAnswerFixture {
        FlaggedAnswerFixture(
            query: "what did we decide with Akhil on the media team",
            route: "summarySearch",
            resultTitle: "Recent Akhil Context",
            resultText: "Decision: ship the weekly update on Friday.",
            supportingSnippets: [
                "Core(EANSG): few things: have our builders showcase",
                "AI Weekends: lifi will confirm their 5k in a bit."
            ],
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
            appVersion: "1.0.8",
            commitSHA: "abc1234"
        )
    }

    /// The attachment text IS the consent surface — everything that
    /// could be sent must appear in it, so the user sees the full
    /// payload in the attachment panel before keeping or removing it.
    func testAttachmentTextContainsEveryShareableField() {
        let attachment = makeFixture().attachmentText()

        XCTAssertTrue(attachment.contains("what did we decide with Akhil on the media team"))
        XCTAssertTrue(attachment.contains("summarySearch"))
        XCTAssertTrue(attachment.contains("Recent Akhil Context"))
        XCTAssertTrue(attachment.contains("Decision: ship the weekly update on Friday."))
        XCTAssertTrue(attachment.contains("Core(EANSG)"))
        XCTAssertTrue(attachment.contains("1.0.8 (abc1234)"))
    }

    /// The attachment rides along with the user's typed note, so it
    /// must stay bounded even with pathological inputs.
    func testAttachmentStaysBoundedEvenWithOversizedInputs() {
        let fixture = FlaggedAnswerFixture(
            query: String(repeating: "q", count: 300),
            route: "agenticSearch",
            resultTitle: nil,
            resultText: String(repeating: "r", count: 5_000),
            supportingSnippets: (0..<20).map { i in String(repeating: "s\(i)", count: 400) }
        )

        let attachment = fixture.attachmentText()
        XCTAssertLessThan(attachment.count, 1_900)
    }

    func testWriteLocalFixtureRoundTrips() throws {
        let fixture = makeFixture()
        let fileURL = try fixture.writeLocalFixture(directoryOverride: tempDirectory)

        XCTAssertTrue(fileURL.path.hasPrefix(tempDirectory.path), "fixture must land in the given directory")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FlaggedAnswerFixture.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(decoded.query, fixture.query)
        XCTAssertEqual(decoded.route, "summarySearch")
        XCTAssertEqual(decoded.supportingSnippets.count, 2)
    }

    func testSnippetAndResultCapsApply() {
        let fixture = FlaggedAnswerFixture(
            query: "q",
            route: "semanticSearch",
            resultTitle: nil,
            resultText: String(repeating: "x", count: 1_000),
            supportingSnippets: (0..<10).map { _ in String(repeating: "y", count: 500) }
        )
        XCTAssertEqual(fixture.supportingSnippets.count, 5)
        XCTAssertEqual(fixture.supportingSnippets[0].count, 150)
        XCTAssertEqual(fixture.resultText?.count, 600)
    }
}
