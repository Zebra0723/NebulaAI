// Timing every stage with a monotonic clock, and a rolling log of how long
// they took, without allocating on the per-frame path.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum Monotonic {
    /// Nanoseconds on the system's monotonic clock (the camera's presentation
    /// timestamps are on the same clock on macOS: mach host time).
    @inline(__always)
    public static func nanoseconds() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        #endif
    }

    @inline(__always)
    public static func seconds() -> Double { Double(nanoseconds()) / 1e9 }
}

/// A fixed-size ring of samples in milliseconds. `record` never allocates;
/// `percentiles` copies and sorts, so call it from the UI, not the hot path.
public final class LatencyLog: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    public let capacity: Int
    private var next = 0
    public private(set) var count = 0
    private let lock = SpinLock()

    public init(capacity: Int = 4096) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    @inline(__always)
    public func record(_ ms: Float) {
        lock.lock()
        buffer[next] = ms
        next = (next + 1) % capacity
        if count < capacity { count += 1 }
        lock.unlock()
    }

    public func samples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<count).map { buffer[$0] }
    }

    public func reset() {
        lock.lock()
        next = 0
        count = 0
        lock.unlock()
    }

    public func percentiles() -> Percentiles { Percentiles(samples()) }
}

public struct Percentiles: Codable, Sendable, Equatable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double

    public init(_ values: [Float]) {
        let sorted = values.sorted()
        count = sorted.count
        func at(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let i = Swift.min(sorted.count - 1, Swift.max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))
            return Double(sorted[i])
        }
        p50 = at(0.5)
        p95 = at(0.95)
        p99 = at(0.99)
        max = Double(sorted.last ?? 0)
    }

    public init(count: Int, p50: Double, p95: Double, p99: Double, max: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
    }
}

/// The smallest lock there is: the critical sections are a few stores long.
final class SpinLock: @unchecked Sendable {
    #if canImport(Darwin)
    private let l: UnsafeMutablePointer<os_unfair_lock>
    init() {
        l = .allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
    }
    deinit { l.deallocate() }
    @inline(__always) func lock() { os_unfair_lock_lock(l) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(l) }
    #else
    private let m: UnsafeMutablePointer<pthread_mutex_t>
    init() {
        m = .allocate(capacity: 1)
        pthread_mutex_init(m, nil)
    }
    deinit {
        pthread_mutex_destroy(m)
        m.deallocate()
    }
    @inline(__always) func lock() { pthread_mutex_lock(m) }
    @inline(__always) func unlock() { pthread_mutex_unlock(m) }
    #endif
}
