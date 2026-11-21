import AppKit
import WebKit

final class PendingOrderAlertService {
  typealias Execute = (PlatformPageDescriptor, String, [String: Any], @escaping ([String: Any]) -> Void) -> Void
  typealias Send = (PendingOrderAlertSettings, String, @escaping (String, String?) -> Void) -> Void
  private let injectedExecute: Execute?
  private let injectedSend: Send?
  var sources: () -> [PlatformPageDescriptor] = { [] }
  var expectedUsername: (String) -> String = { _ in "" }
  var allowsNPG: (PlatformPageDescriptor) -> Bool = { _ in false }
  private(set) var ledger: PendingOrderAlertLedger?
  private(set) var message = "报警未开启"
  private(set) var statuses: [String: String] = [:]
  private var store: PendingOrderAlertStore?
  private var timer: Timer?
  private var maintenance = Date.distantPast
  private var due: [String: Date] = [:]
  private var active = Set<String>()
  private var epoch = UUID()
  private var blocked = false
  private var sending = false
  private var nextSend = Date.distantPast
  private let transport = PendingOrderTelegramTransport()
  private var candidates: [Candidate] = []
  private struct Candidate {
    let page: PlatformPageDescriptor
    let username: String
    let contextID: String
    let scope: String
    var orders: [[String: Any]]
  }
  init(directory: URL, execute: Execute? = nil, send: Send? = nil) {
    injectedExecute = execute; injectedSend = send
    do {
      let store = try PendingOrderAlertStore(directory: directory); self.store = store
      ledger = PendingOrderAlertLedger(data: try store.load(), save: store.save)
      try ledger?.prune(now: Date())
    } catch { blocked = true; message = "报警存储无法读取或保存，已停止发送；请保留记录并检查本地文件" }
  }
  var settings: PendingOrderAlertSettings { ledger?.data.settings ?? PendingOrderAlertSettings() }
  var records: [PendingOrderAlertRecord] { ledger?.data.records.sorted { $0.at > $1.at } ?? [] }
  func isSelected(_ id: String) -> Bool { settings.selectedPlatformIDs?.contains(id) == true }
  func selectPlatform(_ id: String, selected: Bool) throws {
    guard sources().contains(where: { $0.credentialID == id }) else { throw PendingOrderAlertError.message("平台已移除，请刷新列表") }
    var next = settings
    var ids = Set(next.selectedPlatformIDs ?? [])
    if selected { ids.insert(id) } else { ids.remove(id) }
    next.selectedPlatformIDs = ids.sorted()
    do { try configure(next) }
    catch { failStorage(); throw PendingOrderAlertError.message(message) }
  }
  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    tick()
  }
  func stop() {
    timer?.invalidate(); timer = nil; epoch = UUID(); candidates = []
    transport.stop()
    for page in sources() { page.webView.evaluateJavaScript("window.__smsPendingAlertsRun=null;window.__smsPendingAlertsAbort?.abort();void 0", completionHandler: nil) }
  }
  func configure(_ settings: PendingOrderAlertSettings) throws {
    guard !blocked, let ledger else { throw PendingOrderAlertError.message(message) }
    try ledger.configure(settings)
    epoch = UUID(); candidates = []; due = [:]
    message = settings.enabled ? "报警已开启，等待只读查询" : "报警已关闭"
  }
  private func failStorage() { blocked = true; candidates = []; message = "报警记录无法持久保存，已停止发送" }
  func tick() {
    guard !blocked, let ledger else { return }
    if settings.selectedPlatformIDs == nil {
      var next = settings
      next.selectedPlatformIDs = Array(Set(sources().map(\.credentialID))).sorted()
      do { try ledger.configure(next) } catch { failStorage(); return }
    }
    let now = Date()
    if now.timeIntervalSince(maintenance) >= 60 {
      do { try ledger.prune(now: now); maintenance = now } catch { failStorage(); return }
    }
    guard settings.enabled else { return }
    let pages = sources(); let ids = Set(pages.map(\.credentialID))
    statuses = statuses.filter { ids.contains($0.key) }; due = due.filter { ids.contains($0.key) }
    for page in pages where active.count < 2 && !active.contains(page.credentialID)
      && !candidates.contains(where: { $0.page.credentialID == page.credentialID }) && (due[page.credentialID] ?? .distantPast) <= now {
      query(page)
    }
    if !sending && now >= nextSend { drain() }
  }
  private func current(_ page: PlatformPageDescriptor, username: String) -> Bool {
    sources().contains { $0.credentialID == page.credentialID && $0.startURL == page.startURL && $0.webView === page.webView }
      && expectedUsername(page.credentialID) == username
      && page.webView.url?.host == page.startURL.host && page.webView.url?.scheme == page.startURL.scheme
      && page.webView.url?.port == page.startURL.port && !page.webView.isLoading
  }
  private func query(_ page: PlatformPageDescriptor) {
    let username = expectedUsername(page.credentialID), generation = epoch, requestID = UUID().uuidString
    due[page.credentialID] = Date().addingTimeInterval(60)
    guard current(page, username: username) else { statuses[page.credentialID] = "页面未就绪"; return }
    active.insert(page.credentialID); statuses[page.credentialID] = "查询中"
    let now = Date()
    let args: [String: Any] = ["expectedUsername": username, "allowNPG": allowsNPG(page), "requestID": requestID,
      "startDate": PendingOrderAlertRules.day(now.addingTimeInterval(-Double(settings.lookbackDays - 1) * 86400)),
      "endDate": PendingOrderAlertRules.day(now)]
    var finished = false
    let finish: ([String: Any]) -> Void = { [weak self] result in
      guard let self, !finished else { return }; finished = true
      self.active.remove(page.credentialID); self.due[page.credentialID] = Date().addingTimeInterval(60)
      guard self.epoch == generation, self.settings.enabled, self.current(page, username: username) else { return }
      guard result["kind"] as? String == "ok", let orders = result["orders"] as? [[String: Any]],
        let contextID = result["contextID"] as? String, let family = result["family"] as? String,
        ["NPG", "TC"].contains(family) else {
        self.statuses[page.credentialID] = "未完整获取，本轮不报警"; return
      }
      let scopeParts = [page.startURL.scheme ?? "", page.startURL.host ?? "", String(page.startURL.port ?? 443),
        family, result["country"] as? String ?? "", result["merchant"] as? String ?? ""]
      let scope = String(data: try! JSONEncoder().encode(scopeParts), encoding: .utf8)!
      let eligible = self.eligible(orders, scope: scope)
      self.statuses[page.credentialID] = "已查 \(orders.count) 条 · 待提醒 \(self.isSelected(page.credentialID) ? eligible.count : 0) 条"
      if self.isSelected(page.credentialID), !eligible.isEmpty {
        self.candidates.append(Candidate(page: page, username: username, contextID: contextID, scope: scope, orders: eligible))
      }
    }
    execute(page, script: PendingOrdersScript.alertQuery, args: args, finish: finish)
    DispatchQueue.main.asyncAfter(deadline: .now() + 145) { [weak view = page.webView] in
      guard !finished else { return }
      view?.evaluateJavaScript("if(window.__smsPendingAlertsRun==='\(requestID)'){window.__smsPendingAlertsRun=null;window.__smsPendingAlertsAbort?.abort()}void 0", completionHandler: nil)
      finish([:])
    }
  }
  private func eligible(_ orders: [[String: Any]], scope: String) -> [[String: Any]] {
    let now = Date(), keys = Set(ledger?.data.records.map(\.key) ?? [])
    return orders.filter { row in
      guard let id = row["id"] as? String, !id.isEmpty, id.count <= 160,
        ["待处理", "待审核", "支付", "放款异常"].contains(row["status"] as? String ?? "") else { return false }
      return !keys.contains(PendingOrderAlertRules.key(scope: scope, order: id, now: now))
        && PendingOrderAlertRules.eligible(created: PendingOrderTiming.date(milliseconds: row["createdAt"] as? Double),
          observed: PendingOrderTiming.date(milliseconds: row["observedAt"] as? Double), now: now, minutes: settings.minutes)
    }
  }
  private func drain() {
    guard settings.enabled, !blocked, let ledger, !candidates.isEmpty else { return }
    var candidate = candidates.removeFirst()
    guard isSelected(candidate.page.credentialID), current(candidate.page, username: candidate.username) else { return }
    candidate.orders = eligible(candidate.orders, scope: candidate.scope)
    guard !candidate.orders.isEmpty else { return }
    let generation = epoch; sending = true
    var validated = false
    let finish: ([String: Any]) -> Void = { [weak self] result in
      guard let self, !validated else { return }; validated = true
      guard self.epoch == generation, self.settings.enabled, !self.blocked, self.isSelected(candidate.page.credentialID),
        result["kind"] as? String == "ok", self.current(candidate.page, username: candidate.username) else { self.sending = false; return }
      let rows = Array(self.eligible(candidate.orders, scope: candidate.scope).prefix(10)), now = Date()
      do {
        let records = try ledger.reserve(scope: candidate.scope, platform: candidate.page.displayName,
          orders: rows.compactMap { $0["id"] as? String }, now: now)
        guard !records.isEmpty else { self.sending = false; return }
        let ids = Set(records.map(\.orderID)), keys = Set(records.map(\.key))
        let lines = rows.filter { ids.contains($0["id"] as? String ?? "") }.map { row -> String in
          let date = PendingOrderTiming.date(milliseconds: row["createdAt"] as? Double)!
          return "订单 \(PendingOrderAlertRules.clean(row["id"] as? String ?? "")) | \(Int(now.timeIntervalSince(date) / 60)) 分钟 | \(row["status"] as? String ?? "")\n创建 \(PendingOrderTiming.formatter.string(from: date))"
        }
        let text = "提现挂单报警\n\(PendingOrderAlertRules.clean(candidate.page.displayName)) · 超过 \(self.settings.minutes) 分钟\n" + lines.joined(separator: "\n") + "\n查询时间（北京时间）：\(PendingOrderTiming.formatter.string(from: now))"
        let remaining = candidate.orders.filter { !ids.contains($0["id"] as? String ?? "") }
        if !remaining.isEmpty { var next = candidate; next.orders = remaining; self.candidates.append(next) }
        let sender: Send = self.injectedSend ?? { settings, text, finish in self.transport.send(settings: settings, text: text, completion: finish) }
        sender(self.settings, text) { [weak self] state, id in
          guard let self else { return }
          do { try ledger.complete(keys: keys, state: state, messageID: id) } catch { self.failStorage() }
          self.sending = false; self.nextSend = Date().addingTimeInterval(3.2)
          if !self.blocked { self.message = self.settings.enabled ? "最近发送：" + state : "报警已关闭" }
        }
      } catch { self.sending = false; self.failStorage() }
    }
    execute(candidate.page, script: PendingOrdersScript.alertValidate, args: ["expectedUsername": candidate.username,
      "allowNPG": allowsNPG(candidate.page), "contextID": candidate.contextID], finish: finish)
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish([:]) }
  }
  private func execute(_ page: PlatformPageDescriptor, script: String, args: [String: Any], finish: @escaping ([String: Any]) -> Void) {
    if let injectedExecute { injectedExecute(page, script, args, finish); return }
    page.webView.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { result in
      DispatchQueue.main.async { finish((try? result.get()) as? [String: Any] ?? [:]) }
    }
  }
}
