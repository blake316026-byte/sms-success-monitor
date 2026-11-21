import AppKit
import WebKit
import Foundation

struct PlatformPageDescriptor {
  let credentialID: String
  let displayName: String
  let startURL: URL
  let webView: WKWebView
}
final class AlertFixtureWebView: WKWebView {
  override var url: URL? { URL(string: "https://fixture.invalid/31690")! }
  override var isLoading: Bool { false }
}
@main struct PendingOrderAlertsCheck {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sms-alert-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1795190340)
    precondition(PendingOrderAlertRules.day(now) == "2026-11-20")
    precondition(PendingOrderAlertRules.day(now.addingTimeInterval(120)) == "2026-11-21")
    precondition(!PendingOrderAlertRules.eligible(created: now.addingTimeInterval(-1200), observed: now, now: now, minutes: 20))
    precondition(PendingOrderAlertRules.eligible(created: now.addingTimeInterval(-1200.001), observed: now, now: now, minutes: 20))
    precondition(!PendingOrderAlertRules.eligible(created: nil, observed: now, now: now, minutes: 20))
    precondition(!PendingOrderAlertRules.eligible(created: now.addingTimeInterval(-2000), observed: now.addingTimeInterval(-121), now: now, minutes: 20))
    precondition(!PendingOrderAlertRules.eligible(created: now.addingTimeInterval(1), observed: now, now: now, minutes: 20))
    let store = try PendingOrderAlertStore(directory: root)
    let ledger = PendingOrderAlertLedger(data: try store.load(), save: store.save)
    precondition(!ledger.data.settings.enabled)
    let settings = PendingOrderAlertSettings(enabled: true, minutes: 20, lookbackDays: 7,
      token: "123456:" + String(repeating: "x", count: 30), chatID: "-100123456789", selectedPlatformIDs: ["fixture"])
    try ledger.configure(settings)
    let first = try ledger.reserve(scope: "merchant-a", platform: "Fixture", orders: ["1", "1"], now: now)
    precondition(first.count == 1)
    let recovered = try store.load()
    precondition(recovered.records[0].state == "发送待确认")
    let restart = PendingOrderAlertLedger(data: recovered, save: store.save)
    let duplicate = try restart.reserve(scope: "merchant-a", platform: "Fixture", orders: ["1"], now: now)
    precondition(duplicate.isEmpty)
    let other = try restart.reserve(scope: "merchant-b", platform: "Other", orders: ["1"], now: now)
    precondition(other.count == 1)
    let tomorrow = try restart.reserve(scope: "merchant-a", platform: "Fixture", orders: ["1"], now: now.addingTimeInterval(120))
    precondition(tomorrow.count == 1)
    try restart.prune(now: now.addingTimeInterval(86400)); precondition(restart.data.records.count == 1)
    try restart.prune(now: now.addingTimeInterval(86520)); precondition(restart.data.records.isEmpty)
    do { try restart.prune(now: now); preconditionFailure("clock rollback accepted") } catch {}
    do { _ = try PendingOrderAlertStore(directory: root); preconditionFailure("second sender acquired lock") } catch {}
    let bytes = try Data(contentsOf: root.appendingPathComponent("withdrawal-alerts-v1/state.encrypted"))
    precondition(!String(decoding: bytes, as: UTF8.self).contains(settings.token))
    let failing = PendingOrderAlertLedger(data: PendingOrderAlertData(), save: { _ in throw PendingOrderAlertError.message("disk") })
    do { _ = try failing.reserve(scope: "a", platform: "a", orders: ["1"], now: now); preconditionFailure("save failure accepted") } catch {}
    precondition(failing.data.records.isEmpty)

    _ = NSApplication.shared
    let web = AlertFixtureWebView()
    let page = PlatformPageDescriptor(credentialID: "fixture", displayName: "测试平台", startURL: web.url!, webView: web)
    var calls = 0, sends = 0, expected = "fixture"
    let service = PendingOrderAlertService(directory: root.appendingPathComponent("service"), execute: { _, script, _, finish in
      calls += 1
      if script == PendingOrdersScript.alertQuery {
        let milliseconds = Date().timeIntervalSince1970 * 1000
        finish(["kind": "ok", "family": "TC", "merchant": "m", "contextID": "run",
          "orders": [["id": "fixture-order", "status": "待处理", "createdAt": milliseconds - 1300000, "observedAt": milliseconds]]])
      } else { finish(["kind": "ok"]) }
    }, send: { _, text, finish in
      sends += 1; precondition(text.contains("fixture-order")); precondition(!text.contains(settings.token))
      finish("发送待确认", nil)
    })
    service.sources = { [page] }; service.expectedUsername = { _ in expected }
    service.tick(); precondition(calls == 0 && sends == 0)
    try service.configure(settings); service.tick(); precondition(calls == 2 && sends == 1)
    precondition(service.records.first?.state == "发送待确认")
    service.tick(); precondition(sends == 1)
    try service.selectPlatform("fixture", selected: false)
    precondition(!service.isSelected("fixture")); service.tick(); precondition(sends == 1)
    try service.selectPlatform("fixture", selected: true)
    service.tick(); precondition(sends == 1, "reselection must not reset daily dedupe")
    var off = settings; off.enabled = false; try service.configure(off); expected = "changed"; service.tick(); precondition(sends == 1)
    let window = PendingOrderAlertWindowController(service: service); window.present()
    window.window?.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    let controls = descendants(window.window!.contentView!)
    let tabs = controls.compactMap { $0 as? NSSegmentedControl }.first!
    tabs.selectedSegment = 1; NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
    let table = descendants(window.window!.contentView!).compactMap { $0 as? NSTableView }.first!
    precondition(table.tableColumns.filter { !$0.isHidden }.map(\.title) == ["TG 报警", "平台", "查询结果"])
    let checkbox = window.tableView(table, viewFor: table.tableColumn(withIdentifier: .init("selected")), row: 0) as! NSButton
    checkbox.performClick(nil); precondition(!service.isSelected("fixture"))
    checkbox.performClick(nil); precondition(service.isSelected("fixture"))
    precondition(service.records.count == 1 && sends == 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    if let path = ProcessInfo.processInfo.environment["SMS_ALERT_PREVIEW_PATH"], let view = window.window?.contentView,
      let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: image)
      try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    precondition(window.window!.minSize.width >= 760)
    window.close(); service.stop()
    let migrationRoot = root.appendingPathComponent("migration")
    do {
      let store = try PendingOrderAlertStore(directory: migrationRoot)
      var old = PendingOrderAlertData(); old.version = 1; old.settings = off; old.settings.selectedPlatformIDs = nil
      old.records = [PendingOrderAlertRecord(key: String(repeating: "a", count: 64), platform: "测试平台", orderID: "old", at: Date(), state: "已发送")]
      try store.save(old)
    }
    let migrated = PendingOrderAlertService(directory: migrationRoot)
    var platforms = [page]; migrated.sources = { platforms }; migrated.tick()
    precondition(migrated.isSelected("fixture") && migrated.ledger?.data.version == 2)
    precondition(migrated.settings.token == off.token && migrated.settings.chatID == off.chatID && migrated.records.count == 1)
    platforms.append(PlatformPageDescriptor(credentialID: "new", displayName: "新平台", startURL: web.url!, webView: web))
    migrated.tick(); precondition(!migrated.isSelected("new"))
    try migrated.selectPlatform("fixture", selected: false); migrated.tick()
    precondition(migrated.settings.selectedPlatformIDs == [])
    var callback: (([String: Any]) -> Void)?
    var blockedSends = 0
    let delayed = PendingOrderAlertService(directory: root.appendingPathComponent("delayed"), execute: { _, script, _, finish in
      if script == PendingOrdersScript.alertQuery {
        let ms = Date().timeIntervalSince1970 * 1000
        finish(["kind": "ok", "family": "TC", "merchant": "m", "contextID": "run",
          "orders": [["id": "delay-order", "status": "待处理", "createdAt": ms - 1300000, "observedAt": ms]]])
      } else { callback = finish }
    }, send: { _, _, finish in blockedSends += 1; finish("已发送", "1") })
    delayed.sources = { [page] }; try delayed.configure(settings); delayed.tick()
    precondition(callback != nil)
    try delayed.selectPlatform("fixture", selected: false); callback?(["kind": "ok"])
    precondition(blockedSends == 0 && delayed.records.isEmpty)
    delayed.stop(); migrated.stop()
    print("PASS: native TG threshold, Beijing day, daily/restart dedupe, 24h cleanup, encryption, sender lock, fail-closed storage, background service and settings window")
  }
}
