/// Runs `body` for each element with at most `limit` operations in flight.
/// The first error cancels the remaining work and is rethrown.
public func forEachConcurrently<Element: Sendable>(
    _ elements: [Element],
    limit: Int,
    _ body: @escaping @Sendable (Element) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var iterator = elements.makeIterator()
        for _ in 0..<max(1, limit) {
            guard let element = iterator.next() else { break }
            group.addTask { try await body(element) }
        }
        while try await group.next() != nil {
            if let element = iterator.next() {
                group.addTask { try await body(element) }
            }
        }
    }
}
