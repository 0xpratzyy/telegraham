import Foundation

/// Passthrough provider used when no AI API key is configured.
/// Returns empty/default results so the app degrades gracefully.
final class NoAIProvider: AIProvider {
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        throw AIError.providerNotConfigured
    }

    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64] {
        throw AIError.providerNotConfigured
    }

    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        return (true, "")
    }

    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO {
        throw AIError.providerNotConfigured
    }

    func discoverDashboardTopics(messages: [MessageSnippet]) async throws -> [DashboardTopicDTO] {
        throw AIError.providerNotConfigured
    }

    func extractDashboardTasks(
        chat: TGChat,
        topics: [DashboardTopic],
        messages: [MessageSnippet]
    ) async throws -> [DashboardTaskCandidate] {
        throw AIError.providerNotConfigured
    }

    func triageDashboardTaskCandidates(
        candidates: [DashboardTaskTriageCandidateDTO]
    ) async throws -> [DashboardTaskTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func testConnection() async throws -> Bool {
        throw AIError.providerNotConfigured
    }
}
