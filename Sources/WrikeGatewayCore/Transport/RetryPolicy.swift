import Foundation

/// Injected clock and sleeper seams so retry and expiry decisions are
/// deterministic in tests.
public protocol GatewayClock: Sendable {
  var now: Date { get }
  func sleep(seconds: Double) async throws
}

public struct SystemClock: GatewayClock {
  public init() {}
  public var now: Date { Date() }

  public func sleep(seconds: Double) async throws {
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

/// Bounded retry for GET requests only.
///
/// Create, update, delete, OAuth token exchange, refresh rotation, and
/// attachment upload are excluded because none of them has a reviewed
/// idempotency guarantee.
public struct RetryPolicy: Sendable, Equatable {
  public let maximumAttempts: Int
  public let baseDelaySeconds: Double
  public let maximumDelaySeconds: Double
  public let maximumElapsedSeconds: Double
  /// Deterministic jitter fraction; tests set it to zero.
  public let jitterFraction: Double

  public init(
    maximumAttempts: Int = 3,
    baseDelaySeconds: Double = 0.5,
    maximumDelaySeconds: Double = 8,
    maximumElapsedSeconds: Double = 30,
    jitterFraction: Double = 0.2
  ) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.baseDelaySeconds = baseDelaySeconds
    self.maximumDelaySeconds = maximumDelaySeconds
    self.maximumElapsedSeconds = maximumElapsedSeconds
    self.jitterFraction = jitterFraction
  }

  public static let disabled = RetryPolicy(maximumAttempts: 1)

  /// Returns the delay before `attempt` (1-based) is retried, or `nil` when the
  /// request must not be retried again.
  public func delayBeforeRetry(
    attempt: Int,
    method: HTTPMethod,
    retryAfterSeconds: Int?,
    elapsedSeconds: Double
  ) -> Double? {
    guard method.isAutomaticallyRetryable else { return nil }
    guard attempt < maximumAttempts else { return nil }
    guard elapsedSeconds < maximumElapsedSeconds else { return nil }

    if let retryAfterSeconds {
      let delay = min(Double(retryAfterSeconds), maximumDelaySeconds)
      return elapsedSeconds + delay <= maximumElapsedSeconds ? delay : nil
    }

    let exponential = baseDelaySeconds * pow(2, Double(attempt - 1))
    let capped = min(exponential, maximumDelaySeconds)
    // Deterministic jitter derived from the attempt index keeps retry timing
    // reproducible in tests while still spreading concurrent clients.
    let jitter = capped * jitterFraction * (Double(attempt % 3) / 2)
    return min(capped + jitter, maximumDelaySeconds)
  }

  /// Whether an HTTP status is eligible for a bounded retry.
  public static func isRetryable(status: Int) -> Bool {
    status == 429 || (500...599).contains(status)
  }
}
