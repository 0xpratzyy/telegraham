import XCTest
@testable import Pidgy

final class EmbeddingDiagnosticTests: XCTestCase {
    func testContextualProviderProducesVectors() async throws {
        let provider = AppleContextualEmbeddingProvider()
        let prepared = await provider.prepare()
        print("DIAG contextual prepared=\(prepared)")
        try XCTSkipIf(!prepared, "contextual assets unavailable on this machine")

        let vector = await provider.embed(text: "what did we decide about the office space")
        print("DIAG contextual vector dims=\(vector?.count ?? -1) first3=\(vector?.prefix(3).map { String(format: "%.4f", $0) } ?? [])")
        XCTAssertNotNil(vector)
        XCTAssertGreaterThan(vector?.count ?? 0, 0)

        let active = await EmbeddingService.shared.activeModelVersion
        print("DIAG activeModelVersion=\(active)")
        let serviceVector = await EmbeddingService.shared.embed(text: "what did we decide about the office space")
        print("DIAG service vector dims=\(serviceVector?.count ?? -1)")
        XCTAssertNotNil(serviceVector)
    }
}
