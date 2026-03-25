import Foundation

/// Bounded circular buffer for 16 kHz Float samples.
/// Write from the audio callback thread; read once per utterance start.
final class FloatRingBuffer {
    let capacity: Int  // always a power of 2

    private let lock = UnfairLock()
    private var storage: ContiguousArray<Float>
    private var writeHead: Int = 0
    private var filledCount: Int = 0
    private let mask: Int

    /// Creates a ring buffer. Capacity is rounded up to the nearest power of 2.
    init(capacity: Int) {
        precondition(capacity > 0)
        // Round up to power of 2
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        self.storage = ContiguousArray(repeating: 0.0, count: c)
    }

    /// Append samples. Overwrites oldest if full. Safe to call from real-time thread.
    func write(_ ptr: UnsafeBufferPointer<Float>) {
        guard !ptr.isEmpty else { return }
        lock.withLock {
            for sample in ptr {
                storage[writeHead & mask] = sample
                writeHead = (writeHead + 1) & mask
                if filledCount < capacity { filledCount += 1 }
            }
        }
    }

    /// Returns up to `n` most-recent samples in chronological order.
    /// Returns fewer if buffer isn't yet full.
    func readLast(_ n: Int) -> ContiguousArray<Float> {
        lock.withLock {
            let available = min(n, filledCount)
            guard available > 0 else { return ContiguousArray() }

            var result = ContiguousArray<Float>()
            result.reserveCapacity(available)

            // Start from oldest of the `available` samples
            let startHead = (writeHead - available + capacity) & mask
            for i in 0..<available {
                result.append(storage[(startHead + i) & mask])
            }
            return result
        }
    }

    /// Number of samples currently held (0…capacity).
    var count: Int {
        lock.withLock { filledCount }
    }

    /// Clear all samples (e.g., on audio device route change).
    func clear() {
        lock.withLock {
            writeHead = 0
            filledCount = 0
        }
    }
}
