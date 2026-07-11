import Foundation
import SMSMonitorCore

enum AppMonitorState {
  case starting(String)
  case scanning(ScanMetrics?)
  case healthy(ScanMetrics, Date)
  case alert(ScanMetrics, Date)
  case authenticationRequired(String)
  case error(String, Date?)

  var metrics: ScanMetrics? {
    switch self {
    case .scanning(let metrics):
      return metrics
    case .healthy(let metrics, _), .alert(let metrics, _):
      return metrics
    default:
      return nil
    }
  }

  var scannedAt: Date? {
    switch self {
    case .healthy(_, let date), .alert(_, let date):
      return date
    case .error(_, let date):
      return date
    default:
      return nil
    }
  }

  var isAlert: Bool {
    if case .alert = self { return true }
    return false
  }

  var requiresAuthentication: Bool {
    if case .authenticationRequired = self { return true }
    return false
  }

  var isError: Bool {
    if case .error = self { return true }
    return false
  }

  var isHealthy: Bool {
    if case .healthy = self { return true }
    return false
  }
}

struct ModuleMonitorSnapshot {
  let configuration: MonitorConfiguration
  let state: AppMonitorState
  let nextScanAt: Date?
}

struct FleetMonitorSnapshot {
  let modules: [ModuleMonitorSnapshot]

  static func initial(configurations: [MonitorConfiguration]) -> FleetMonitorSnapshot {
    FleetMonitorSnapshot(
      modules: configurations.map {
        ModuleMonitorSnapshot(
          configuration: $0,
          state: .starting("等待连接"),
          nextScanAt: nil
        )
      }
    )
  }

  var focus: ModuleMonitorSnapshot? {
    let summaries = modules.compactMap { module -> ModuleMetricsSummary? in
      guard let metrics = module.state.metrics else { return nil }
      return ModuleMetricsSummary(
        moduleID: module.configuration.id,
        metrics: metrics,
        alertThreshold: module.configuration.alertThreshold
      )
    }

    if let lowestAlert = MonitorAggregateSelector.lowestAlert(in: summaries) {
      return modules.first { $0.configuration.id == lowestAlert.moduleID }
    }
    if let lowestRate = MonitorAggregateSelector.lowestRate(in: summaries) {
      return modules.first { $0.configuration.id == lowestRate.moduleID }
    }
    if let authentication = modules.first(where: { $0.state.requiresAuthentication }) {
      return authentication
    }
    if let error = modules.first(where: { $0.state.isError }) {
      return error
    }
    return modules.first
  }

  var alertCount: Int {
    modules.count(where: {
      guard let metrics = $0.state.metrics else { return false }
      return metrics.shouldAlert(threshold: $0.configuration.alertThreshold)
    })
  }

  var healthyCount: Int {
    modules.count(where: { $0.state.isHealthy })
  }

  var authenticationCount: Int {
    modules.count(where: { $0.state.requiresAuthentication })
  }

  var errorCount: Int {
    modules.count(where: { $0.state.isError })
  }
}
