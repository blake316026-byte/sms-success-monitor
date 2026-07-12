import Foundation

public enum ScanRecoveryPolicy {
  public static let defaultFailureThreshold = 2

  public static func shouldReload(
    consecutiveFailures: Int,
    threshold: Int = defaultFailureThreshold
  ) -> Bool {
    threshold > 0 && consecutiveFailures >= threshold
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

  public static let bills02 = MonitorConfiguration(
    id: "bills02-otp",
    displayName: "BIllS02-OTP",
    targetURL: URL(
      string: "https://qgxucm.npgaaa.com/sms-record-list#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let bills = MonitorConfiguration(
    id: "bills",
    displayName: "BIllS",
    targetURL: URL(
      string: "https://jns7yi.npgaaa.com/app-user-list#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000001")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let bills3 = MonitorConfiguration(
    id: "bills3",
    displayName: "BIllS3",
    targetURL: URL(
      string: "https://6dxogz.npgaaa.com/recharge-record-list#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000003")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let bills4 = MonitorConfiguration(
    id: "bills4",
    displayName: "BIllS4",
    targetURL: URL(
      string:
        "https://sfk75o.npgaaa.com/v-report/3878C493EB934C22817480D595ABAFC9#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000004")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let cg01 = MonitorConfiguration(
    id: "cg01",
    displayName: "cg01",
    targetURL: URL(
      string: "https://jklm65.npgaaa.com/ck-dashboard#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000101")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let cg02 = MonitorConfiguration(
    id: "cg02",
    displayName: "cg02",
    targetURL: URL(
      string: "https://afzp7r.npgaaa.com/login#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000102")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let cg03 = MonitorConfiguration(
    id: "cg03-nine01",
    displayName: "cg03（nine01）",
    targetURL: URL(
      string:
        "https://ijdzzs.npgaaa.com/v-report/3878C493EB934C22817480D595ABAFC9#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000103")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let cg04 = MonitorConfiguration(
    id: "cg04",
    displayName: "cg04",
    targetURL: URL(
      string: "https://cd0byx.npgaaa.com/login#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000104")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let bs01 = MonitorConfiguration(
    id: "bs01",
    displayName: "bs01",
    targetURL: URL(
      string: "https://93zwv9.npgaaa.com/login#CC=eyJDT1VOVFJZIjoiUEgifQ=="
    )!,
    profileIdentifier: UUID(uuidString: "53D12001-4A6B-4C00-9000-000000000201")!,
    sampleLimit: 200,
    scanInterval: 60,
    alertThreshold: 0.50
  )

  public static let allModules: [MonitorConfiguration] = [
    .bills02,
    .bills,
    .bills3,
    .bills4,
    .cg01,
    .cg02,
    .cg03,
    .cg04,
    .bs01,
  ]
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
