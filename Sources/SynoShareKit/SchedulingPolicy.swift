import Foundation

/// Exponential backoff with jitter: 1 s, 2 s, 4 s … capped at 60 s, at most 8 attempts.
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60, maxAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// Delay before retry number `attempt` (1-based). "Equal jitter": half fixed,
    /// half random, so parallel workers do not retry in lock-step. `random` is in 0...1.
    public func delay(afterAttempt attempt: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 30)))
        let ceiling = min(maxDelay, baseDelay * pow(2, exponent))
        return ceiling / 2 + ceiling / 2 * min(max(random, 0), 1)
    }

    public func shouldGiveUp(afterAttempts attempts: Int) -> Bool { attempts >= maxAttempts }
}

/// Adaptive file concurrency (DECISIONS #10): start at `maximum`, drop to `minimum`
/// after repeated throttling signals (429/503/timeouts), ramp back one step per
/// run of successes.
public struct AdaptiveConcurrency: Sendable, Equatable {
    public let maximum: Int
    public let minimum: Int
    /// Consecutive throttling signals that trigger the drop.
    public let throttleThreshold: Int
    /// Consecutive successes needed to add one slot back.
    public let rampUpAfter: Int
    public private(set) var current: Int
    private var throttleStreak = 0
    private var successStreak = 0

    public init(maximum: Int = 3, minimum: Int = 1, throttleThreshold: Int = 3, rampUpAfter: Int = 20) {
        self.maximum = max(1, maximum)
        self.minimum = max(1, min(minimum, maximum))
        self.throttleThreshold = max(1, throttleThreshold)
        self.rampUpAfter = max(1, rampUpAfter)
        current = self.maximum
    }

    public mutating func recordThrottle() {
        successStreak = 0
        throttleStreak += 1
        if throttleStreak >= throttleThreshold {
            current = minimum
            throttleStreak = 0
        }
    }

    public mutating func recordSuccess() {
        throttleStreak = 0
        successStreak += 1
        if successStreak >= rampUpAfter, current < maximum {
            current += 1
            successStreak = 0
        }
    }
}

/// Exponentially weighted moving average of throughput, in bytes per second.
public struct SpeedEstimator: Sendable, Equatable {
    public let smoothing: Double
    public private(set) var bytesPerSecond: Double = 0
    private var hasSample = false

    public init(smoothing: Double = 0.2) { self.smoothing = min(max(smoothing, 0.01), 1) }

    public mutating func add(bytes: Int64, over seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let sample = Double(max(bytes, 0)) / seconds
        bytesPerSecond = hasSample ? smoothing * sample + (1 - smoothing) * bytesPerSecond : sample
        hasSample = true
    }

    /// Seconds left at the current speed, nil while the speed is unknown.
    public func eta(remainingBytes: Int64) -> TimeInterval? {
        guard bytesPerSecond > 0 else { return nil }
        return Double(max(remainingBytes, 0)) / bytesPerSecond
    }
}
