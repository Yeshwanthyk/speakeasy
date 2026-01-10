import Foundation
import os

final class UnfairLock {
    private var lock = os_unfair_lock_s()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return try body()
    }
}
