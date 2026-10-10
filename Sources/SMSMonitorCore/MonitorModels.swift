import Foundation

public struct DailyFinancialMetrics: Equatable, Sendable {
  public let countryID: String
  public let rechargeAmount: Double
  public let withdrawAmount: Double

  public init(countryID: String, rechargeAmount: Double, withdrawAmount: Double) {
    self.countryID = countryID
    self.rechargeAmount = rechargeAmount
    self.withdrawAmount = withdrawAmount
  }

  public var differenceAmount: Double {
    rechargeAmount - withdrawAmount
  }

  public var differenceRatio: Double? {
    guard rechargeAmount.isFinite, rechargeAmount != 0 else { return nil }
    let ratio = differenceAmount / rechargeAmount
    return ratio.isFinite ? ratio : nil
  }
}

public struct CountryFinancialTotal: Equatable, Sendable {
  public let countryID: String
  public let platformCount: Int
  public let metrics: DailyFinancialMetrics
}

public enum FinancialCountrySummary {
  public static func totals(_ metrics: [DailyFinancialMetrics]) -> [CountryFinancialTotal] {
    let grouped = Dictionary(grouping: metrics.filter { !$0.countryID.isEmpty }, by: \.countryID)
    return grouped.keys.sorted().compactMap { countryID in
      guard let values = grouped[countryID] else { return nil }
      return CountryFinancialTotal(
        countryID: countryID,
        platformCount: values.count,
        metrics: DailyFinancialMetrics(
          countryID: countryID,
          rechargeAmount: values.reduce(0) { $0 + $1.rechargeAmount },
          withdrawAmount: values.reduce(0) { $0 + $1.withdrawAmount }
        )
      )
    }
  }
}

public enum ScanRecoveryPolicy {
  public static let defaultFailureThreshold = 2

  public static func shouldReload(
    consecutiveFailures: Int,
    threshold: Int = defaultFailureThreshold
  ) -> Bool {
    threshold > 0 && consecutiveFailures >= threshold
  }
}

public enum AutoLoginAttemptPolicy {
  public static let maximumCaptchaAttempts = 10
  public static let maximumTOTPAttempts = 5

  public static func canAttemptCaptcha(afterFailures failures: Int) -> Bool {
    failures < maximumCaptchaAttempts
  }

  public static func canAttemptTOTP(afterFailures failures: Int) -> Bool {
    failures < maximumTOTPAttempts
  }
}

public enum MonitorRefreshPolicy {
  public static let minimumNextScanDelay: TimeInterval = 1
  public static let minimumStaleAge: TimeInterval = 4 * 60
  public static let maximumStartupSpread: TimeInterval = 180

  public static func nextScanDelay(
    scanInterval: TimeInterval,
    scanDuration: TimeInterval
  ) -> TimeInterval {
    max(minimumNextScanDelay, scanInterval - max(0, scanDuration))
  }

  public static func staleAge(scanInterval: TimeInterval) -> TimeInterval {
    max(minimumStaleAge, scanInterval * 4)
  }

  public static func resultIsStale(
    scannedAt: Date,
    now: Date,
    scanInterval: TimeInterval
  ) -> Bool {
    now.timeIntervalSince(scannedAt) > staleAge(scanInterval: scanInterval)
  }

  public static func staggeredDelay(
    index: Int,
    count: Int,
    maximumSpread: TimeInterval = maximumStartupSpread
  ) -> TimeInterval {
    guard count > 1, index > 0 else { return 0 }
    let boundedIndex = min(index, count - 1)
    return max(0, maximumSpread) * Double(boundedIndex) / Double(count - 1)
  }
}

public enum InactivePageMaintenancePolicy {
  public static let compactAfter: TimeInterval = 30

  public static func shouldCompact(
    isActive: Bool,
    inactiveSince: Date?,
    lastSuccessfulScanAt: Date?,
    now: Date,
    scanInterval: TimeInterval
  ) -> Bool {
    guard !isActive,
      let inactiveSince,
      let lastSuccessfulScanAt,
      now.timeIntervalSince(inactiveSince) >= compactAfter,
      now.timeIntervalSince(lastSuccessfulScanAt)
        <= max(2 * scanInterval, MonitorRefreshPolicy.minimumNextScanDelay)
    else { return false }

    return true
  }
}

public enum SampleLimitPolicy {
  public static let defaultValue = 200
  public static let minimumValue = 10
  public static let maximumValue = 500

  public static func normalize(_ value: Int) -> Int {
    min(maximumValue, max(minimumValue, value))
  }
}

public struct MonitorConfiguration: Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let targetURL: URL
  public let profileIdentifier: UUID?
  public let sampleLimit: Int
  public let scanInterval: TimeInterval
  public let alertThreshold: Double

  public init(
    id: String,
    displayName: String,
    targetURL: URL,
    profileIdentifier: UUID? = nil,
    sampleLimit: Int,
    scanInterval: TimeInterval,
    alertThreshold: Double
  ) {
    self.id = id
    self.displayName = displayName
    self.targetURL = targetURL
    self.profileIdentifier = profileIdentifier
    self.sampleLimit = sampleLimit
    self.scanInterval = scanInterval
    self.alertThreshold = alertThreshold
  }

  public static let allModules: [MonitorConfiguration] = []

}

public struct ScanMetrics: Equatable, Sendable {
  public let sampleCount: Int
  public let successCount: Int

  public init(sampleCount: Int, successCount: Int) {
    self.sampleCount = max(0, sampleCount)
    self.successCount = min(max(0, successCount), max(0, sampleCount))
  }

  public var nonSuccessCount: Int {
    sampleCount - successCount
  }

  public var successRate: Double {
    guard sampleCount > 0 else { return 0 }
    return Double(successCount) / Double(sampleCount)
  }

  public func shouldAlert(threshold: Double) -> Bool {
    sampleCount > 0 && successRate < threshold
  }

  public var percentageText: String {
    guard sampleCount > 0 else { return "--" }
    let percentage = successRate * 100
    if percentage.rounded() == percentage {
      return String(format: "%.0f%%", percentage)
    }
    return String(format: "%.1f%%", percentage)
  }
}

public enum MetricsCalculator {
  public static func calculate(statuses: [String], sampleLimit: Int) -> ScanMetrics {
    let boundedStatuses = Array(statuses.prefix(max(0, sampleLimit)))
    let successes = boundedStatuses.reduce(into: 0) { count, status in
      if status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "SUCCESS" {
        count += 1
      }
    }
    return ScanMetrics(sampleCount: boundedStatuses.count, successCount: successes)
  }
}

public struct ModuleMetricsSummary: Equatable, Sendable {
  public let moduleID: String
  public let metrics: ScanMetrics
  public let alertThreshold: Double

  public init(moduleID: String, metrics: ScanMetrics, alertThreshold: Double) {
    self.moduleID = moduleID
    self.metrics = metrics
    self.alertThreshold = alertThreshold
  }

  public var isAlert: Bool {
    metrics.shouldAlert(threshold: alertThreshold)
  }
}

public enum MonitorAggregateSelector {
  public static func lowestAlert(
    in summaries: [ModuleMetricsSummary]
  ) -> ModuleMetricsSummary? {
    lowestRate(in: summaries.filter(\.isAlert))
  }

  public static func lowestRate(
    in summaries: [ModuleMetricsSummary]
  ) -> ModuleMetricsSummary? {
    summaries.min { left, right in
      if left.metrics.successRate == right.metrics.successRate {
        return left.moduleID < right.moduleID
      }
      return left.metrics.successRate < right.metrics.successRate
    }
  }
}
