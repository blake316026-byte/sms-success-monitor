import Foundation

enum PendingOrderTiming {
  static let limit: TimeInterval = 20 * 60
  static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  static func date(milliseconds: Double?) -> Date? {
    guard let milliseconds, milliseconds.isFinite,
      milliseconds >= 946684800000, milliseconds < 4102444800000 else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  static func isOverdue(createdAt: Date?, now: Date, confirmed: Bool) -> Bool {
    guard confirmed, let createdAt else { return false }
    return now.timeIntervalSince(createdAt) > limit
  }

  static func matchesMinimumWait(createdAt: Date?, minutes: Int, now: Date) -> Bool {
    guard minutes > 0 else { return true }
    guard let createdAt else { return false }
    return now.timeIntervalSince(createdAt) >= Double(minutes) * 60
  }

  static func waitingText(createdAt: Date?, now: Date, confirmed: Bool) -> String {
    guard let createdAt else { return "时间未获取" }
    let elapsed = now.timeIntervalSince(createdAt)
    guard elapsed >= 0 else { return "时间异常" }
    let minutes = Int(elapsed / 60)
    let duration = minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    if !confirmed { return duration + "（待核实）" }
    return (elapsed > limit ? "超时 · " : "") + duration
  }
}
