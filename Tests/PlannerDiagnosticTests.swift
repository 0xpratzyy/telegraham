import XCTest
@testable import Pidgy

/// Manual diagnostic — runs the REAL query planner against live queries
/// and prints its raw plan, so routing/merge gates can be debugged with
/// ground truth instead of guesses. Gated; costs a few cents.
///   TEST_RUNNER_PIDGY_PLANNER_DIAG=1 xcodebuild ... \
///     -only-testing:PidgyTests/PlannerDiagnosticTests test
final class PlannerDiagnosticTests: XCTestCase {
    func testPlannerOutputForLiveQueries() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_PLANNER_DIAG"] == "1" else {
            throw XCTSkip("Manual diagnostic — run with PIDGY_PLANNER_DIAG=1")
        }
        guard let key = BundledSecrets.openAIApiKey, !key.isEmpty else {
            throw XCTSkip("No bundled OpenAI key in this build")
        }
        let provider = OpenAIProvider(apiKey: key)
        let interpreter = QueryInterpreter()

        for query in [
            "grampus chat me kya ho rha",
            "firstdollar ki latest discussions batao"
        ] {
            let baseSpec = interpreter.parse(
                query: query, now: Date(), timezone: .current, activeFilter: .all
            )
            print("DIAG query: \(query)")
            print("DIAG base: family=\(baseSpec.family.rawValue) engine=\(baseSpec.preferredEngine.rawValue) conf=\(baseSpec.parseConfidence)")
            do {
                let plan = try await provider.planQuery(
                    query: query, activeFilter: .all, deterministicSpec: baseSpec
                )
                print("DIAG plan: family=\(plan.family) conf=\(plan.confidence) people=\(plan.people) topics=\(plan.topicTerms) scope=\(plan.scope) time=\(plan.timeRange)")
            } catch {
                print("DIAG plan FAILED: \(error)")
            }
        }
    }
}
