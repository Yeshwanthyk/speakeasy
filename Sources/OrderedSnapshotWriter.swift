import Foundation

/// Enqueues snapshot writes synchronously so a store's serial queue observes
/// the same order as its main-actor mutations.
final class OrderedSnapshotWriter: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        func finish(_ result: Bool) {
            let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                guard self.result == nil else { return [] }
                self.result = result
                defer { self.waiters.removeAll() }
                return self.waiters
            }
            waiters.forEach { $0.resume(returning: result) }
        }

        func value() async -> Bool {
            await withCheckedContinuation { continuation in
                let completedResult = lock.withLock { () -> Bool? in
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let completedResult {
                    continuation.resume(returning: completedResult)
                }
            }
        }
    }

    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func enqueue(_ operation: @escaping @Sendable () -> Bool) -> Task<Bool, Never> {
        let completion = Completion()
        queue.async {
            completion.finish(operation())
        }
        return Task { await completion.value() }
    }
}
