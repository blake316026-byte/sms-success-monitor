import AppKit
import SMSMonitorCore
import UserNotifications

final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
  private let notificationCenter = UNUserNotificationCenter.current()
  private let notificationIdentifier = "sms-success-rate-alert"
  private var mutedUntil: Date?

  override init() {
    super.init()
    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  var muteDescription: String? {
    guard let mutedUntil, mutedUntil > Date() else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return "已静音至 \(formatter.string(from: mutedUntil))"
  }

  func notify(configuration: MonitorConfiguration, metrics: ScanMetrics) {
    guard mutedUntil == nil || mutedUntil! <= Date() else { return }

    notificationCenter.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])

    let content = UNMutableNotificationContent()
    content.title = "\(configuration.displayName) 短信成功率报警"
    let threshold = Int(configuration.alertThreshold * 100)
    content.body =
      "最新 \(metrics.sampleCount) 条成功 \(metrics.successCount) 条，成功率 \(metrics.percentageText)，低于 \(threshold)%。"
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: notificationIdentifier,
      content: content,
      trigger: nil
    )
    notificationCenter.add(request)
    NSApp.requestUserAttention(.criticalRequest)
  }

  func clearAlert() {
    notificationCenter.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
  }

  func muteForTenMinutes() {
    mutedUntil = Date().addingTimeInterval(10 * 60)
    clearAlert()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
