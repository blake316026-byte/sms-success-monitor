import Foundation
import SMSMonitorCore

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() {
    print("PASS: \(message)")
  } else {
    failures += 1
    print("FAIL: \(message)")
  }
}

let belowThreshold = MetricsCalculator.calculate(
  statuses: Array(repeating: "SUCCESS", count: 99) + Array(repeating: "SENT", count: 101),
  sampleLimit: 200
)
check(belowThreshold.sampleCount == 200, "uses the latest 200 statuses")
check(belowThreshold.successCount == 99, "counts only successful statuses")
check(belowThreshold.nonSuccessCount == 101, "counts non-success statuses")
check(belowThreshold.percentageText == "49.5%", "formats fractional success rates")
check(belowThreshold.shouldAlert(threshold: 0.50), "alerts below fifty percent")

let exactThreshold = MetricsCalculator.calculate(
  statuses: Array(repeating: "SUCCESS", count: 100) + Array(repeating: "FAILED", count: 100),
  sampleLimit: 200
)
check(exactThreshold.percentageText == "50%", "formats whole-number success rates")
check(!exactThreshold.shouldAlert(threshold: 0.50), "does not alert at exactly fifty percent")

let mixedStatuses = MetricsCalculator.calculate(
  statuses: ["SUCCESS", " success ", "SENT", "PENDING", "SEND_ERROR", "FAILED", ""],
  sampleLimit: 200
)
check(mixedStatuses.successCount == 2, "normalizes whitespace and case only")

let cappedSample = MetricsCalculator.calculate(
  statuses: Array(repeating: "SUCCESS", count: 250),
  sampleLimit: 200
)
check(cappedSample.sampleCount == 200, "caps oversized responses at the configured sample")

let emptySample = MetricsCalculator.calculate(statuses: [], sampleLimit: 200)
check(!emptySample.shouldAlert(threshold: 0.50), "does not alert for an empty sample")

check(
  !ScanRecoveryPolicy.shouldReload(consecutiveFailures: 1),
  "keeps the normal retry path after one scan failure"
)
check(
  ScanRecoveryPolicy.shouldReload(consecutiveFailures: 2),
  "reloads the platform context after two consecutive scan failures"
)
check(
  MonitorRefreshPolicy.nextScanDelay(scanInterval: 60, scanDuration: 20) == 40,
  "keeps a one-minute cadence after a fast scan"
)
check(
  MonitorRefreshPolicy.nextScanDelay(scanInterval: 60, scanDuration: 75) == 1,
  "reschedules immediately after a scan overruns its interval"
)
let refreshReference = Date(timeIntervalSince1970: 1_000)
check(
  !MonitorRefreshPolicy.resultIsStale(
    scannedAt: refreshReference,
    now: refreshReference.addingTimeInterval(240),
    scanInterval: 60
  ),
  "keeps a result valid at the stale boundary"
)
check(
  MonitorRefreshPolicy.resultIsStale(
    scannedAt: refreshReference,
    now: refreshReference.addingTimeInterval(241),
    scanInterval: 60
  ),
  "expires a result that has not refreshed for four minutes"
)
check(SampleLimitPolicy.normalize(75) == 75, "keeps a valid custom sample limit")
check(
  SampleLimitPolicy.normalize(1) == SampleLimitPolicy.minimumValue,
  "clamps sample limits below the supported range"
)
check(
  SampleLimitPolicy.normalize(10_000) == SampleLimitPolicy.maximumValue,
  "clamps sample limits above the supported range"
)

let configuredModules = MonitorConfiguration.allModules
check(configuredModules.count == 9, "configures all nine monitored platforms")
check(
  configuredModules.map(\.displayName) == [
    "BIllS02-OTP",
    "BIllS",
    "BIllS3",
    "BIllS4",
    "cg01",
    "cg02",
    "cg03（nine01）",
    "cg04",
    "bs01",
  ],
  "preserves the configured backend names"
)
check(
  Set(configuredModules.map(\.id)).count == configuredModules.count,
  "uses unique module identifiers"
)
check(
  Set(configuredModules.compactMap { $0.targetURL.host }).count == configuredModules.count,
  "uses one independent origin per monitored platform"
)
check(
  configuredModules.compactMap(\.profileIdentifier).count == 8,
  "keeps the existing primary session and isolates eight added sessions"
)

let aggregateCandidates = [
  ModuleMetricsSummary(
    moduleID: "bills02-otp",
    metrics: ScanMetrics(sampleCount: 200, successCount: 69),
    alertThreshold: 0.50
  ),
  ModuleMetricsSummary(
    moduleID: "bills3",
    metrics: ScanMetrics(sampleCount: 200, successCount: 82),
    alertThreshold: 0.50
  ),
  ModuleMetricsSummary(
    moduleID: "cg01",
    metrics: ScanMetrics(sampleCount: 200, successCount: 96),
    alertThreshold: 0.50
  ),
  ModuleMetricsSummary(
    moduleID: "bills",
    metrics: ScanMetrics(sampleCount: 200, successCount: 154),
    alertThreshold: 0.50
  ),
]
check(
  MonitorAggregateSelector.lowestAlert(in: aggregateCandidates)?.moduleID == "bills02-otp",
  "selects the lowest success rate among alerting platforms"
)
check(
  MonitorAggregateSelector.lowestRate(in: aggregateCandidates)?.metrics.percentageText == "34.5%",
  "selects the lowest available rate for aggregate display"
)
check(
  MonitorAggregateSelector.lowestAlert(
    in: [
      ModuleMetricsSummary(
        moduleID: "healthy",
        metrics: ScanMetrics(sampleCount: 200, successCount: 100),
        alertThreshold: 0.50
      )
    ]
  ) == nil,
  "does not report an aggregate alert at exactly fifty percent"
)

if failures > 0 {
  print("\(failures) core check(s) failed")
  exit(1)
}

print("All core checks passed")
