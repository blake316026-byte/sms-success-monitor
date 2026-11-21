import AppKit
import WebKit
import OSLog

struct PendingOrderRow {
  let platformID: String
  let platform: String
  let orderID: String
  let status: String
  let contextID: String
  let family: String
  let startDate: String
  let endDate: String
  var createdAt: Date? = nil
  var observedAt: Date? = nil
  var reviewerName: String? = nil
  var allReviewers = false
  var isReviewQuery: Bool { reviewerName != nil || allReviewers }
  var usesNPGAudit: Bool { isReviewQuery || (family == "NPG" && status == "待审核") }
}

private final class PendingOrderTableRowView: NSTableRowView {
  var overdue = false
  override func drawBackground(in dirtyRect: NSRect) {
    super.drawBackground(in: dirtyRect)
    if overdue && !isSelected {
      NSColor.systemRed.withAlphaComponent(0.10).setFill()
      dirtyRect.fill()
    }
  }
}

final class PendingOrdersWindowController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
  var sources: () -> [PlatformPageDescriptor] = { [] }
  var expectedUsername: (String) -> String = { _ in "" }
  var allowsNPG: (PlatformPageDescriptor) -> Bool = { _ in false }
  var openOrder: ((PendingOrderRow) -> Void)?
  var showAlerts: (() -> Void)?
  private let table = NSTableView()
  private let search = NSSearchField()
  private let platformFilter = NSPopUpButton()
  private let from = NSDatePicker()
  private let through = NSDatePicker()
  private let summary = NSTextField(labelWithString: "")
  private let autoRefresh = NSButton(checkboxWithTitle: "自动刷新", target: nil, action: nil)
  private let refresh = NSButton()
  private let views = NSSegmentedControl(labels: ["订单", "平台状态"], trackingMode: .selectOne, target: nil, action: nil)
  private let intervalField = NSTextField(string: "60")
  private let intervalStepper = NSStepper()
  private let minimumWaitField = NSTextField(string: "")
  private let minimumWaitControls = NSStackView()
  private var minimumWaitMinutes = 0
  private let previousPage = NSButton()
  private let nextPage = NSButton()
  private let pageLabel = NSTextField(labelWithString: "")
  private var pageIndex = 0
  private var pageCount = 1
  private let pageSize = 10
  private var refreshSeconds = 60
  private static let intervalKey = "SMSMonitor.PendingOrdersRefreshSeconds.v1"
  private var rows: [PendingOrderRow] = []
  private var displayed: [PendingOrderRow] = []
  private var statuses: [String: String] = [:]
  private var names: [String: String] = [:]
  private var filterIDs: [String] = [""]
  private var queue: [PlatformPageDescriptor] = []
  private var active = 0
  private var generation = UUID()
  private var timer: Timer?
  private var ageTimer: Timer?
  private var confirmedPlatforms = Set<String>()
  private var queriedViews: [WKWebView] = []
  private var completed = 0
  private var succeeded = 0
  private var total = 0
  private var running = false
  private var pendingNavigation = false
  private var navigationMessage: String?
  private static let dateFormat: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 530),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "全平台待处理订单"
    window.minSize = NSSize(width: 960, height: 400)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let content = NSView(); window.contentView = content
    for picker in [from, through] {
      picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = [.yearMonthDay]
      picker.locale = Locale(identifier: "zh_CN"); picker.calendar = Calendar(identifier: .gregorian)
      picker.target = self; picker.action = #selector(dateChanged)
    }
    through.dateValue = Date()
    from.dateValue = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    search.placeholderString = "平台 / 订单号 / 状态"; search.delegate = self
    search.widthAnchor.constraint(equalToConstant: 210).isActive = true
    platformFilter.target = self; platformFilter.action = #selector(filterChanged)
    platformFilter.addItem(withTitle: "全部平台")
    platformFilter.widthAnchor.constraint(equalToConstant: 140).isActive = true
    refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
    refresh.bezelStyle = .texturedRounded; refresh.toolTip = "刷新待处理订单"
    refresh.target = self; refresh.action = #selector(refreshClicked)
    refresh.widthAnchor.constraint(equalToConstant: 32).isActive = true
    autoRefresh.state = .on
    autoRefresh.target = self; autoRefresh.action = #selector(refreshSettingsChanged)
    refreshSeconds = Self.normalizedInterval(UserDefaults.standard.object(forKey: Self.intervalKey) as? Int ?? 60)
    intervalField.integerValue = refreshSeconds; intervalField.alignment = .right
    intervalField.widthAnchor.constraint(equalToConstant: 54).isActive = true
    intervalField.target = self; intervalField.action = #selector(intervalEdited); intervalField.delegate = self
    intervalField.setAccessibilityLabel("自动刷新间隔秒数")
    intervalField.toolTip = "自动刷新间隔，最少 5 秒"
    intervalStepper.minValue = 5; intervalStepper.maxValue = 3600; intervalStepper.increment = 5
    intervalStepper.integerValue = refreshSeconds; intervalStepper.target = self; intervalStepper.action = #selector(intervalStepped)
    views.selectedSegment = 0; views.target = self; views.action = #selector(filterChanged)
    views.setWidth(90, forSegment: 0); views.setWidth(110, forSegment: 1)
    let minutesFormatter = NumberFormatter()
    minutesFormatter.numberStyle = .none; minutesFormatter.allowsFloats = false; minutesFormatter.minimum = 0
    minimumWaitField.formatter = minutesFormatter; minimumWaitField.placeholderString = "不限"
    minimumWaitField.alignment = .right
    minimumWaitField.widthAnchor.constraint(equalToConstant: 65).isActive = true
    minimumWaitField.delegate = self; minimumWaitField.target = self; minimumWaitField.action = #selector(minimumWaitEdited)
    minimumWaitField.setAccessibilityLabel("最少等待分钟数")
    minimumWaitControls.orientation = .horizontal; minimumWaitControls.spacing = 8
    for item in [NSTextField(labelWithString: "等待时长 ≥"), minimumWaitField, NSTextField(labelWithString: "分钟")] {
      minimumWaitControls.addArrangedSubview(item)
    }
    let options = NSStackView(views: [views, NSTextField(labelWithString: "刷新间隔"), intervalField, intervalStepper, NSTextField(labelWithString: "秒"), minimumWaitControls])
    options.orientation = .horizontal; options.spacing = 8
    let alerts = NSButton(title: "TG 报警", target: self, action: #selector(openAlerts))
    alerts.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "TG 报警")
    alerts.imagePosition = .imageLeading; alerts.toolTip = "TG 挂单报警设置"
    alerts.bezelStyle = .texturedRounded; options.addArrangedSubview(alerts)
    for (button, symbol, label, action) in [(previousPage, "chevron.left", "上一页", #selector(previousClicked)), (nextPage, "chevron.right", "下一页", #selector(nextClicked))] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
      button.bezelStyle = .texturedRounded; button.toolTip = label; button.target = self; button.action = action
      button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }
    pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    pageLabel.alignment = .center; pageLabel.widthAnchor.constraint(equalToConstant: 280).isActive = true
    let pager = NSStackView(views: [previousPage, pageLabel, nextPage]); pager.spacing = 8
    let bar = NSStackView(views: [NSTextField(labelWithString: "日期"), from,
      NSTextField(labelWithString: "至"), through, platformFilter, search, autoRefresh, refresh])
    bar.orientation = .horizontal; bar.spacing = 8
    summary.font = .systemFont(ofSize: 12); summary.textColor = .secondaryLabelColor
    summary.lineBreakMode = .byTruncatingTail
    for (id, title, width) in [("platform", "对应平台", 125.0), ("order", "订单号", 160.0),
      ("created", "订单创建时间（北京时间）", 200.0), ("age", "等待时长", 175.0), ("status", "订单状态 / 查询结果", 240.0)] {
      let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title
      c.width = width; c.minWidth = id == "created" ? 195 : 110; table.addTableColumn(c)
    }
    table.dataSource = self; table.delegate = self; table.rowHeight = 30
    table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.allowsMultipleSelection = false
    let scroll = NSScrollView(); scroll.documentView = table
    scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    for view in [bar, options, summary, scroll, pager] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
      options.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12), options.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      options.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
      summary.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10), summary.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), scroll.bottomAnchor.constraint(equalTo: pager.topAnchor, constant: -10),
      pager.centerXAnchor.constraint(equalTo: content.centerXAnchor), pager.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
    ])
  }

  required init?(coder: NSCoder) { nil }
  @objc private func openAlerts() { showAlerts?() }

  static func verifyLayoutAndFiltering() -> Bool {
    let controller = PendingOrdersWindowController()
    let now = Date()
    let old = now.addingTimeInterval(-1200.001), boundary = now.addingTimeInterval(-1200)
    guard PendingOrderTiming.isOverdue(createdAt: old, now: now, confirmed: true),
      !PendingOrderTiming.isOverdue(createdAt: boundary, now: now, confirmed: true),
      !PendingOrderTiming.isOverdue(createdAt: old, now: now, confirmed: false),
      !PendingOrderTiming.isOverdue(createdAt: nil, now: now, confirmed: true),
      !PendingOrderTiming.isOverdue(createdAt: now.addingTimeInterval(1), now: now, confirmed: true),
      PendingOrderTiming.date(milliseconds: .nan) == nil,
      PendingOrderTiming.formatter.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01 08:00:00"
      else { return false }
    guard PendingOrderTiming.matchesMinimumWait(createdAt: now.addingTimeInterval(-300), minutes: 5, now: now),
      !PendingOrderTiming.matchesMinimumWait(createdAt: now.addingTimeInterval(-299.999), minutes: 5, now: now),
      !PendingOrderTiming.matchesMinimumWait(createdAt: nil, minutes: 5, now: now),
      !PendingOrderTiming.matchesMinimumWait(createdAt: now.addingTimeInterval(1), minutes: 5, now: now),
      PendingOrderTiming.matchesMinimumWait(createdAt: nil, minutes: 0, now: now) else { return false }
    controller.rows = [PendingOrderRow(platformID: "fixture", platform: "Example TC", orderID: "100000000001",
      status: "待审核", contextID: "test", family: "TC", startDate: "2026-10-04", endDate: "2026-10-10")]
    controller.names = ["fixture": "Example TC", "unavailable": "NPG"]
    controller.statuses = ["fixture": "已获取 1 条", "unavailable": "未获取：需登录"]
    controller.total = 2; controller.completed = 2; controller.succeeded = 1
    controller.render()
    guard controller.displayed.count == 1 else { return false }
    controller.views.selectedSegment = 1; controller.filterChanged()
    guard controller.displayed.count == 2 else { return false }
    controller.views.selectedSegment = 0; controller.filterChanged()
    controller.search.stringValue = "100000000001"; controller.render()
    guard controller.displayed.count == 1, controller.displayed.first?.platform == "Example TC" else { return false }
    controller.search.stringValue = ""
    let fixture = controller.rows[0]
    controller.rows = (0..<25).map { index -> PendingOrderRow in
      let offset: TimeInterval = index == 3 ? 60 : (index == 0 ? -1800 : -300)
      let createdAt: Date? = index == 2 ? nil : now.addingTimeInterval(offset)
      return PendingOrderRow(platformID: fixture.platformID, platform: fixture.platform,
        orderID: String(10000 + index), status: fixture.status, contextID: fixture.contextID,
        family: fixture.family, startDate: fixture.startDate, endDate: fixture.endDate,
        createdAt: createdAt, observedAt: now)
    }
    controller.confirmedPlatforms.insert(fixture.platformID)
    controller.render()
    guard controller.isOverdue(controller.rows[0]), !controller.isOverdue(controller.rows[1]),
      controller.summary.stringValue.contains("超时 1 条"),
      controller.tableView(controller.table, rowViewForRow: 0) is PendingOrderTableRowView else { return false }
    controller.confirmedPlatforms.removeAll(); controller.render()
    guard !controller.isOverdue(controller.rows[0]), controller.summary.stringValue.contains("超时 0 条") else { return false }
    controller.confirmedPlatforms.insert(fixture.platformID); controller.render()
    guard controller.displayed.count == 10, controller.pageCount == 3, !controller.previousPage.isEnabled, controller.nextPage.isEnabled else { return false }
    controller.nextClicked(); controller.nextClicked()
    guard controller.displayed.count == 5, controller.displayed[0].orderID == "10020", !controller.nextPage.isEnabled else { return false }
    controller.search.stringValue = "10024"; controller.filterChanged()
    guard controller.displayed.count == 1, controller.pageIndex == 0 else { return false }
    controller.search.stringValue = ""; controller.filterChanged()
    controller.nextClicked()
    controller.minimumWaitField.stringValue = "5"; controller.minimumWaitEdited()
    guard controller.pageIndex == 0, controller.pageCount == 3, controller.pageLabel.stringValue.contains("共 23 条"),
      controller.displayed.allSatisfy({ $0.createdAt != nil && $0.createdAt! <= now }) else { return false }
    controller.minimumWaitField.stringValue = "20"; controller.minimumWaitEdited()
    guard controller.displayed.count == 1, controller.displayed[0].orderID == "10000" else { return false }
    controller.search.stringValue = "10024"; controller.filterChanged()
    guard controller.displayed.isEmpty else { return false }
    controller.search.stringValue = ""
    controller.views.selectedSegment = 1; controller.filterChanged()
    guard controller.displayed.count == 2, controller.minimumWaitControls.isHidden else { return false }
    controller.views.selectedSegment = 0; controller.filterChanged()
    controller.minimumWaitField.stringValue = "0"; controller.minimumWaitEdited()
    guard controller.pageLabel.stringValue.contains("共 25 条") else { return false }
    controller.minimumWaitField.stringValue = ""; controller.minimumWaitEdited()
    guard controller.pageLabel.stringValue.contains("共 25 条"), !controller.minimumWaitControls.isHidden else { return false }
    guard normalizedInterval(1) == 5, normalizedInterval(5) == 5, normalizedInterval(60) == 60, normalizedInterval(9999) == 3600 else { return false }
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    if let path = ProcessInfo.processInfo.environment["SMS_MONITOR_ORDERS_PREVIEW_PATH"], let view = controller.window?.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
      do { try data.write(to: URL(fileURLWithPath: path)) } catch { return false }
    }
    return controller.table.tableColumns.count == 5
  }

  func present() {
    if window?.isVisible != true { window?.center() }
    showWindow(nil); window?.makeKeyAndOrderFront(nil)
    if ageTimer == nil {
      ageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        guard let self, self.window?.isVisible == true, !self.pendingNavigation else { return }
        self.render()
      }
    }
    if !running { beginRefresh() }
  }

  private static func normalizedInterval(_ seconds: Int) -> Int { min(3600, max(5, seconds)) }

  private func scheduleRefresh() {
    timer?.invalidate(); timer = nil
    guard window?.isVisible == true, autoRefresh.state == .on, !running, !pendingNavigation,
      Self.dateFormat.string(from: from.dateValue) <= Self.dateFormat.string(from: through.dateValue) else { return }
    timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshSeconds), repeats: false) { [weak self] _ in
      guard let self, self.window?.isVisible == true, self.autoRefresh.state == .on,
        !self.running, !self.pendingNavigation else { return }
      self.beginRefresh()
    }
  }

  @objc private func refreshSettingsChanged() { scheduleRefresh() }
  @objc private func intervalEdited() {
    refreshSeconds = Self.normalizedInterval(Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? refreshSeconds)
    intervalField.integerValue = refreshSeconds; intervalStepper.integerValue = refreshSeconds
    UserDefaults.standard.set(refreshSeconds, forKey: Self.intervalKey); scheduleRefresh()
  }
  @objc private func intervalStepped() { intervalField.integerValue = intervalStepper.integerValue; intervalEdited() }
  @objc private func minimumWaitEdited() {
    minimumWaitMinutes = max(0, Int(minimumWaitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    filterChanged()
  }
  func controlTextDidEndEditing(_ obj: Notification) {
    if obj.object as? NSTextField === intervalField { intervalEdited() }
    if obj.object as? NSTextField === minimumWaitField { minimumWaitEdited() }
  }

  func windowWillClose(_ notification: Notification) {
    ageTimer?.invalidate(); ageTimer = nil
    timer?.invalidate(); timer = nil; cancel()
  }

  private func cancel() {
    confirmedPlatforms.removeAll()
    timer?.invalidate(); timer = nil
    generation = UUID(); queue = []; active = 0; running = false
    for view in queriedViews { view.evaluateJavaScript("window.__smsPendingOrdersRun = null; window.__smsPendingOrdersAbort?.abort()", completionHandler: nil) }
    queriedViews = []
  }

  @objc private func refreshClicked() { if !pendingNavigation && !running { beginRefresh() } }
  @objc private func dateChanged() { if !pendingNavigation { pageIndex = 0; rows = []; beginRefresh() } }
  @objc private func filterChanged() { pageIndex = 0; render() }
  @objc private func previousClicked() { pageIndex = max(0, pageIndex - 1); render() }
  @objc private func nextClicked() { pageIndex = min(pageCount - 1, pageIndex + 1); render() }
  func controlTextDidChange(_ obj: Notification) {
    if obj.object as? NSTextField === search { filterChanged() }
    if obj.object as? NSTextField === minimumWaitField { minimumWaitEdited() }
  }

  private func beginRefresh() {
    cancel(); navigationMessage = nil
    statuses = [:]; completed = 0; succeeded = 0
    let first = Self.dateFormat.string(from: from.dateValue), last = Self.dateFormat.string(from: through.dateValue)
    guard first <= last else { rows = []; render(); summary.stringValue = "起始日期不能晚于结束日期"; return }
    queue = sources(); total = queue.count; running = !queue.isEmpty
    names = Dictionary(uniqueKeysWithValues: queue.map { ($0.credentialID, $0.displayName) })
    rows.removeAll { names[$0.platformID] == nil || $0.startDate != first || $0.endDate != last }
    let selected = filterIDs.indices.contains(platformFilter.indexOfSelectedItem) ? filterIDs[platformFilter.indexOfSelectedItem] : ""
    filterIDs = [""] + queue.map(\.credentialID)
    platformFilter.removeAllItems(); platformFilter.addItem(withTitle: "全部平台")
    platformFilter.addItems(withTitles: queue.map(\.displayName))
    platformFilter.selectItem(at: filterIDs.firstIndex(of: selected) ?? 0)
    for page in queue { statuses[page.credentialID] = "等待查询" }
    render(); pump(first: first, last: last, epoch: generation)
    if !running { scheduleRefresh() }
  }

  private func pump(first: String, last: String, epoch: UUID) {
    guard generation == epoch else { return }
    while !queue.isEmpty {
      let page = queue.removeFirst(); active += 1
      statuses[page.credentialID] = "查询中"
      let view = page.webView
      queriedViews.append(view)
      let requestID = UUID().uuidString
      var finished = false
      let finish: ([String: Any]) -> Void = { [weak self, weak view] result in
        guard let self, self.generation == epoch, !finished else { return }
        finished = true; self.active -= 1; self.completed += 1
        self.rows.removeAll { $0.platformID == page.credentialID }
        if let view, self.sources().contains(where: { $0.credentialID == page.credentialID && $0.webView === view }) {
          let kind = result["kind"] as? String ?? "error"
          let items = result["orders"] as? [[String: Any]] ?? []
          let validRows = items.compactMap { item -> PendingOrderRow? in
            guard let id = item["id"] as? String, let status = item["status"] as? String,
              let contextID = result["contextID"] as? String, let family = result["family"] as? String else { return nil }
            return PendingOrderRow(platformID: page.credentialID, platform: page.displayName, orderID: id,
              status: status, contextID: contextID, family: family, startDate: first, endDate: last,
              createdAt: PendingOrderTiming.date(milliseconds: item["createdAt"] as? Double),
              observedAt: PendingOrderTiming.date(milliseconds: item["observedAt"] as? Double))
          }
          self.rows += validRows
          if kind == "ok" || kind == "partial" { self.confirmedPlatforms.insert(page.credentialID) }
          let timedCount = validRows.filter { $0.createdAt != nil }.count
          Logger(subsystem: "com.local.sms-success-monitor", category: "PendingOrders").notice("Pending orders for \(page.credentialID, privacy: .public): kind=\(kind, privacy: .public) count=\(validRows.count) createdTimeCount=\(timedCount)")
          if kind == "ok" { self.succeeded += 1; self.statuses[page.credentialID] = validRows.isEmpty ? "无待处理订单" : "已获取 \(validRows.count) 条" }
          else { self.statuses[page.credentialID] = (kind == "partial" ? "部分结果：" : "未获取：") + (result["message"] as? String ?? "查询失败") }
        } else { self.statuses[page.credentialID] = "页面已替换或关闭，请刷新" }
        self.running = self.active > 0 || !self.queue.isEmpty
        self.render(); self.pump(first: first, last: last, epoch: epoch)
        if !self.running { self.scheduleRefresh() }
      }
      guard let url = view.url, url.host == page.startURL.host, url.scheme == page.startURL.scheme, !view.isLoading else {
        finish(["message": "页面未就绪，请先打开对应后台"]); continue
      }
      view.callAsyncJavaScript(PendingOrdersScript.query, arguments: ["expectedUsername": expectedUsername(page.credentialID),
        "allowNPG": allowsNPG(page), "requestID": requestID, "startDate": first, "endDate": last], in: nil, in: .page) { result in
          DispatchQueue.main.async {
            finish((try? result.get()) as? [String: Any] ?? ["message": "页面查询未完成，请检查登录或网络"])
          }
        }
      DispatchQueue.main.asyncAfter(deadline: .now() + 145) { [weak view] in
        guard !finished else { return }
        view?.evaluateJavaScript("if (window.__smsPendingOrdersRun === '\(requestID)') window.__smsPendingOrdersRun = null", completionHandler: nil)
        finish(["message": "查询超时，未确认订单数量"])
      }
    }
  }

  private func render() {
    let now = Date()
    minimumWaitControls.isHidden = views.selectedSegment != 0
    let id = filterIDs.indices.contains(platformFilter.indexOfSelectedItem) ? filterIDs[platformFilter.indexOfSelectedItem] : ""
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var all = views.selectedSegment == 0 ? rows : []
    if views.selectedSegment == 1 {
      for (platformID, status) in statuses {
        all.append(PendingOrderRow(platformID: platformID, platform: names[platformID] ?? platformID, orderID: "",
          status: status, contextID: "", family: "", startDate: "", endDate: ""))
      }
    }
    let filtered = all.filter { (id.isEmpty || $0.platformID == id)
      && (query.isEmpty || "\($0.platform) \($0.orderID) \($0.status)".localizedCaseInsensitiveContains(query))
      && (views.selectedSegment != 0 || PendingOrderTiming.matchesMinimumWait(createdAt: $0.createdAt, minutes: minimumWaitMinutes, now: now)) }
      .sorted { ($0.platform, $0.orderID) < ($1.platform, $1.orderID) }
    pageCount = max(1, (filtered.count + pageSize - 1) / pageSize); pageIndex = min(pageIndex, pageCount - 1)
    displayed = Array(filtered.dropFirst(pageIndex * pageSize).prefix(pageSize))
    previousPage.isEnabled = pageIndex > 0; nextPage.isEnabled = pageIndex + 1 < pageCount
    pageLabel.stringValue = "共 \(filtered.count) 条 · 第 \(pageIndex + 1) / \(pageCount) 页 · 每页 10 条"
    table.reloadData()
    let overdue = rows.filter { isOverdue($0, now: now) }.count
    let missing = rows.filter { $0.createdAt == nil }.count
    summary.stringValue = navigationMessage ?? "待处理 \(rows.count) 条 · 超时 \(overdue) 条（>20 分钟） · 时间未获取 \(missing) 条 · 查询 \(completed)/\(total) 平台 · \(running ? "刷新中" : "查询完成")"
    summary.textColor = overdue > 0 ? .systemRed : .secondaryLabelColor
  }

  private func isOverdue(_ row: PendingOrderRow, now: Date = Date()) -> Bool {
    !row.orderID.isEmpty && PendingOrderTiming.isOverdue(createdAt: row.createdAt, now: now,
      confirmed: confirmedPlatforms.contains(row.platformID))
  }

  func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = PendingOrderTableRowView()
    view.overdue = displayed.indices.contains(row) && isOverdue(displayed[row])
    return view
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard displayed.indices.contains(row) else { return nil }
    let item = displayed[row]
    if tableColumn?.identifier.rawValue == "order", !item.orderID.isEmpty {
      let button = NSButton(title: item.orderID, target: self, action: #selector(orderClicked(_:)))
      button.isBordered = false; button.alignment = .left; button.contentTintColor = .linkColor
      button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); button.tag = row
      button.toolTip = "在 \(item.platform) 查询此订单"; return button
    }
    let column = tableColumn?.identifier.rawValue
    let label = NSTextField(labelWithString: column == "platform" ? item.platform : column == "status" ? item.status : "--")
    if !item.orderID.isEmpty {
      if column == "created" { label.stringValue = item.createdAt.map(PendingOrderTiming.formatter.string(from:)) ?? "未获取" }
      if column == "age" { label.stringValue = PendingOrderTiming.waitingText(createdAt: item.createdAt, now: Date(),
        confirmed: confirmedPlatforms.contains(item.platformID)) }
      if isOverdue(item) { label.textColor = .systemRed }
      if column == "age" { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: isOverdue(item) ? .semibold : .regular) }
    }
    if tableColumn?.identifier.rawValue == "status", !item.orderID.isEmpty,
      !confirmedPlatforms.contains(item.platformID) { label.stringValue += "（上次结果）" }
    label.lineBreakMode = .byTruncatingTail; label.toolTip = label.stringValue
    if column == "age", let observedAt = item.observedAt {
      label.toolTip = label.stringValue + "；最近查询：" + PendingOrderTiming.formatter.string(from: observedAt) + "（北京时间）"
    }
    if item.orderID.isEmpty { label.textColor = .secondaryLabelColor }
    return label
  }

  @objc private func orderClicked(_ button: NSButton) {
    guard displayed.indices.contains(button.tag), !pendingNavigation else { return }
    let row = displayed[button.tag]
    cancel(); pendingNavigation = true
    from.isEnabled = false; through.isEnabled = false; refresh.isEnabled = false
    for (id, status) in statuses where status == "等待查询" || status == "查询中" { statuses[id] = "查询已暂停" }
    navigationMessage = "正在打开 \(row.platform) 的订单"; render()
    openOrder?(row)
  }

  func finishNavigation(message: String) {
    pendingNavigation = false; navigationMessage = message; summary.stringValue = message
    from.isEnabled = true; through.isEnabled = true; refresh.isEnabled = true; scheduleRefresh()
  }
}
