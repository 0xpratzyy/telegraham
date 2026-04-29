import Foundation

struct QueryRoutingDebugSnapshot: Identifiable {
    let query: String
    let spec: QuerySpec
    let runtimeIntent: QueryIntent

    var id: String { query }
}
