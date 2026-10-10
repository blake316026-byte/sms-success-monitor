import AppKit
import WebKit
import OSLog

final class WithdrawalReviewersWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  var sources: () -> [PlatformPageDescriptor] = { [] }
  var expectedUsername: (String) -> String = { _ in "" }
  var allowsNPG: (PlatformPageDescriptor) -> Bool = { _ in false }
  var openReviewer: ((PendingOrderRow) -> Void)?
  private struct Row { let target: PendingOrderRow; let count: Int }
  private let table = NSTableView()
  private let from = NSDatePicker(), through = NSDatePicker()
  private let search = NSSearchField()
  private let fetchButton = NSButton(title: "获取", target: nil, action: nil)
  private let autoRefresh = NSButton(checkboxWithTitle: "自动查询", target: nil, action: nil)
  private let intervalField = NSTextField(string: "30"), intervalStepper = NSStepper()
  private let defaults: UserDefaults
  private let cache: WithdrawalReviewersCache
  private static let intervalKey = "SMSMonitor.ReviewersRefreshMinutes.v1"
  private static let autoKey = "SMSMonitor.ReviewersAutoRefresh.v1"
  private var refreshMinutes = 30
  private var timer: Timer?, maintenanceTimer: Timer?, readinessTimer: Timer?
  private struct WaitingPage { let sourceURL: URL; let account: String; let start: String; let end: String }
  private var waitingPages: [String: WaitingPage] = [:]
  private var nextRefreshAt: Date?
  private var queryScript = WithdrawalReviewersScript.query
  private var readinessScript = PendingOrdersScript.context + "try { capture(); return true; } catch (_) { return false; }"
  private var probingPages = Set<String>()
  private var activated = false, followsToday = true
  private var selectedDay = WithdrawalReviewersWindowController.formatter.string(from: Date())
  private var savedAt: [String: Date] = [:], cachedPlatforms = Set<String>()
  private var platformTotals: [String: Int] = [:]
  private var navigationTarget: PendingOrderRow?
  private let views = NSSegmentedControl(labels: ["审核人员", "平台状态"], trackingMode: .selectOne, target: nil, action: nil)
  private let summary = NSTextField(labelWithString: "未获取")
  private let previous = NSButton(), next = NSButton()
  private let pageLabel = NSTextField(labelWithString: "")
  private var rows: [Row] = [], displayed: [Row] = []
  private var statuses: [String: String] = [:], names: [String: String] = [:]
  private var generation = UUID(), queried: [WKWebView] = []
  private var running = false, navigating = false, pageIndex = 0, pageCount = 1
  private var completed = 0, succeeded = 0, total = 0
  private static let formatter: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"; return f
  }()

  init(cache: WithdrawalReviewersCache = WithdrawalReviewersCache(), defaults: UserDefaults = .standard) {
    self.cache = cache; self.defaults = defaults
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "提现审核人员查询"; window.minSize = NSSize(width: 800, height: 360); window.isReleasedWhenClosed = false
    super.init(window: window); window.delegate = self
    let content = NSView(); window.contentView = content
    for picker in [from, through] {
      picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = [.yearMonthDay]
      picker.locale = Locale(identifier: "zh_CN"); picker.calendar = Calendar(identifier: .gregorian); picker.dateValue = Date()
      picker.target = self; picker.action = #selector(dateChanged)
    }
    search.placeholderString = "平台 / 审核人员"; search.delegate = self
    search.widthAnchor.constraint(equalToConstant: 200).isActive = true
    fetchButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "获取")
    fetchButton.imagePosition = .imageLeading; fetchButton.bezelStyle = .rounded
    fetchButton.target = self; fetchButton.action = #selector(fetchClicked)
    fetchButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
    refreshMinutes = Self.normalizedInterval(defaults.object(forKey: Self.intervalKey) as? Int ?? 30)
    autoRefresh.state = (defaults.object(forKey: Self.autoKey) as? Bool ?? true) ? .on : .off
    autoRefresh.target = self; autoRefresh.action = #selector(refreshSettingsChanged)
    intervalField.integerValue = refreshMinutes; intervalField.alignment = .right
    intervalField.widthAnchor.constraint(equalToConstant: 54).isActive = true
    intervalField.target = self; intervalField.action = #selector(intervalEdited); intervalField.delegate = self
    intervalStepper.minValue = 1; intervalStepper.maxValue = 1440; intervalStepper.integerValue = refreshMinutes
    intervalStepper.target = self; intervalStepper.action = #selector(intervalStepped)
    views.selectedSegment = 0; views.target = self; views.action = #selector(filterChanged)
    let bar = NSStackView(views: [NSTextField(labelWithString: "日期"), from, NSTextField(labelWithString: "至"), through, search, fetchButton]); bar.spacing = 8
    let options = NSStackView(views: [views, autoRefresh, intervalField, intervalStepper, NSTextField(labelWithString: "分钟")]); options.spacing = 10
    summary.font = .systemFont(ofSize: 12); summary.textColor = .secondaryLabelColor; summary.lineBreakMode = .byTruncatingTail
    for (button, symbol, title, action) in [(previous, "chevron.left", "上一页", #selector(previousClicked)), (next, "chevron.right", "下一页", #selector(nextClicked))] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      button.bezelStyle = .texturedRounded; button.toolTip = title; button.target = self; button.action = action
      button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }
    pageLabel.alignment = .center; pageLabel.widthAnchor.constraint(equalToConstant: 280).isActive = true
    let pager = NSStackView(views: [previous, pageLabel, next]); pager.spacing = 8
    for (id, title, width) in [("platform", "对应平台", 210.0), ("reviewer", "审核人员名称", 300.0), ("count", "审核订单总数", 260.0)] {
      let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; c.minWidth = 160; table.addTableColumn(c)
    }
    table.dataSource = self; table.delegate = self; table.rowHeight = 30
    table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    for v in [bar, options, summary, scroll, pager] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
      options.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12), options.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      options.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
      summary.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 8), summary.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      summary.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
      scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), scroll.bottomAnchor.constraint(equalTo: pager.topAnchor, constant: -10),
      pager.centerXAnchor.constraint(equalTo: content.centerXAnchor), pager.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
    ])
    render()
  }
  required init?(coder: NSCoder) { nil }
  func present() {
    if window?.isVisible != true {
      maintainCache()
      if !running && !navigating { restoreCache() }
      window?.center()
    }
    showWindow(nil); window?.makeKeyAndOrderFront(nil)
    if !activated {
      activated = true
      maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.maintainCache() }
      readinessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkWaitingPages() }
      scheduleRefresh()
    }
  }
  // The report continues refreshing while the app runs, even with this window closed.
  func windowWillClose(_ notification: Notification) {}
  private static func normalizedInterval(_ minutes: Int) -> Int { min(1440, max(1, minutes)) }
  private var dateRange: (String, String) { (Self.formatter.string(from: from.dateValue), Self.formatter.string(from: through.dateValue)) }
  private func scheduleRefresh() {
    timer?.invalidate(); timer = nil
    guard activated, autoRefresh.state == .on, !running, !navigating, dateRange.0 <= dateRange.1 else { return }
    if nextRefreshAt == nil { nextRefreshAt = Date().addingTimeInterval(TimeInterval(refreshMinutes * 60)) }
    timer = Timer.scheduledTimer(withTimeInterval: max(0.1, nextRefreshAt!.timeIntervalSinceNow), repeats: false) { [weak self] _ in
      guard let self, !self.running, !self.navigating, self.autoRefresh.state == .on else { return }
      self.maintainCache(); self.beginFetch()
    }
  }
  @objc private func refreshSettingsChanged() { defaults.set(autoRefresh.state == .on, forKey: Self.autoKey); nextRefreshAt = nil; scheduleRefresh() }
  @objc private func intervalEdited() {
    refreshMinutes = Self.normalizedInterval(Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? refreshMinutes)
    intervalField.integerValue = refreshMinutes; intervalStepper.integerValue = refreshMinutes
    defaults.set(refreshMinutes, forKey: Self.intervalKey); nextRefreshAt = nil; scheduleRefresh()
  }
  @objc private func intervalStepped() { intervalField.integerValue = intervalStepper.integerValue; intervalEdited() }
  func controlTextDidEndEditing(_ obj: Notification) { if obj.object as? NSTextField === intervalField { intervalEdited() } }
  private func restoreCache() {
    rows = []; statuses = [:]; names = [:]; savedAt = [:]; platformTotals = [:]; cachedPlatforms = []; waitingPages = [:]; pageIndex = 0
    for page in sources() {
      names[page.credentialID] = page.displayName
      platformTotals[page.credentialID] = cache.total(platformID: page.credentialID, sourceURL: page.startURL.absoluteString,
        account: expectedUsername(page.credentialID), start: dateRange.0, end: dateRange.1)?.count
      let cachedStatus = cache.status(platformID: page.credentialID, sourceURL: page.startURL.absoluteString,
        account: expectedUsername(page.credentialID), start: dateRange.0, end: dateRange.1)
      let lastStatus = cachedStatus.map { "上次查询 \($0.checkedAt.formatted(date: .omitted, time: .shortened)) · \($0.message)" }
      statuses[page.credentialID] = lastStatus ?? "暂无缓存，等待查询"
      if cachedStatus?.message.contains("页面未就绪") == true || cachedStatus?.message.contains("等待页面恢复") == true {
        waitingPages[page.credentialID] = WaitingPage(sourceURL: page.startURL, account: expectedUsername(page.credentialID), start: dateRange.0, end: dateRange.1)
      }
      guard let entry = cache.matching(platformID: page.credentialID, sourceURL: page.startURL.absoluteString,
        account: expectedUsername(page.credentialID), start: dateRange.0, end: dateRange.1) else { continue }
      rows += entry.people.map { Row(target: PendingOrderRow(platformID: page.credentialID, platform: page.displayName,
        orderID: $0.id, status: "", contextID: "", family: entry.family, startDate: entry.startDate, endDate: entry.endDate, reviewerName: $0.name), count: $0.count) }
      savedAt[page.credentialID] = entry.savedAt; cachedPlatforms.insert(page.credentialID)
      statuses[page.credentialID] = "本地缓存 · \(entry.savedAt.formatted(date: .omitted, time: .shortened))"
        + (lastStatus?.contains("失败") == true || waitingPages[page.credentialID] != nil ? " · \(lastStatus!)" : "")
    }
    summary.stringValue = statuses.isEmpty ? "未获取" : "本地缓存 \(savedAt.count)/\(statuses.count) 平台 · 未缓存 \(statuses.count - savedAt.count) 平台 · \(rows.count) 位人员"
    render()
  }
  private func maintainCache() {
    cache.prune()
    let today = Self.formatter.string(from: Date())
    if followsToday && today != selectedDay && !navigating {
      cancel(); from.dateValue = Date(); through.dateValue = Date(); selectedDay = today
      restoreCache(); scheduleRefresh(); return
    }
    let pages = sources()
    for id in Array(platformTotals.keys) {
      guard let page = pages.first(where: { $0.credentialID == id }),
        cache.total(platformID: id, sourceURL: page.startURL.absoluteString, account: expectedUsername(id), start: dateRange.0, end: dateRange.1) != nil else {
        platformTotals[id] = nil; render(); continue
      }
    }
    let expired = Set(savedAt.keys.filter { id in
      guard let page = pages.first(where: { $0.credentialID == id }) else { return true }
      return cache.matching(platformID: id, sourceURL: page.startURL.absoluteString, account: expectedUsername(id), start: dateRange.0, end: dateRange.1) == nil
    })
    guard !expired.isEmpty else { return }
    rows.removeAll { expired.contains($0.target.platformID) }
    for id in expired { savedAt[id] = nil; cachedPlatforms.remove(id); statuses[id] = "缓存已过期或账号已变化，等待查询" }
    summary.stringValue = "部分缓存已过期或账号已变化，等待查询"; render()
  }
  private func cancel(preserveWaiting: Bool = false) {
    timer?.invalidate(); timer = nil
    generation = UUID(); running = false; probingPages = []
    if !preserveWaiting { waitingPages = [:]; nextRefreshAt = nil }
    for view in queried { view.evaluateJavaScript("window.__smsReviewerRun=null; window.__smsReviewerAbort?.abort()", completionHandler: nil) }
    queried = []; fetchButton.title = "获取"
  }
  @objc private func dateChanged() {
    guard !navigating else { return }
    cancel(); selectedDay = Self.formatter.string(from: Date()); followsToday = dateRange.0 == selectedDay && dateRange.1 == selectedDay
    restoreCache(); scheduleRefresh()
  }
  @objc private func filterChanged() { pageIndex = 0; render() }
  @objc private func previousClicked() { pageIndex = max(0, pageIndex - 1); render() }
  @objc private func nextClicked() { pageIndex = min(pageCount - 1, pageIndex + 1); render() }
  func controlTextDidChange(_ obj: Notification) { if obj.object as? NSTextField === search { filterChanged() } }
  @objc private func fetchClicked() {
    guard !navigating else { return }
    if running { cancel(); summary.stringValue = "已停止获取，保留已有结果"; scheduleRefresh(); return }
    maintainCache(); beginFetch()
  }
  private static func pageReady(_ page: PlatformPageDescriptor) -> Bool {
    guard let url = page.webView.url else { return false }
    return url.host == page.startURL.host && url.scheme == page.startURL.scheme && !page.webView.isLoading
  }
  private func checkWaitingPages() {
    guard activated, autoRefresh.state == .on, !running, !navigating, !waitingPages.isEmpty else { return }
    maintainCache()
    let pages = sources()
    waitingPages = waitingPages.filter { id, scope in
      scope.start == dateRange.0 && scope.end == dateRange.1 && scope.account == expectedUsername(id)
        && pages.contains(where: { $0.credentialID == id && $0.startURL == scope.sourceURL })
    }
    let epoch = generation
    for page in pages where waitingPages[page.credentialID] != nil && !probingPages.contains(page.credentialID) && Self.pageReady(page) {
      probingPages.insert(page.credentialID)
      // Session inspection is local only; no platform API request or navigation.
      page.webView.callAsyncJavaScript(readinessScript, arguments: ["expectedUsername": expectedUsername(page.credentialID),
        "allowNPG": allowsNPG(page), "requiredNPGPermission": "WITHDRAW_AUDIT_RECORD_LIST"], in: nil, in: .page) { [weak self] result in
        DispatchQueue.main.async {
          guard let self, self.generation == epoch else { return }
          self.probingPages.remove(page.credentialID)
          guard (try? result.get()) as? Bool == true, !self.running, !self.navigating, self.autoRefresh.state == .on,
            let scope = self.waitingPages[page.credentialID], scope.account == self.expectedUsername(page.credentialID),
            scope.start == self.dateRange.0, scope.end == self.dateRange.1,
            let current = self.sources().first(where: { $0.credentialID == page.credentialID && $0.startURL == scope.sourceURL }),
            current.webView === page.webView, Self.pageReady(current) else { return }
          Logger(subsystem: "com.local.sms-success-monitor", category: "WithdrawalReviewers").notice("Ready-page retry: \(page.credentialID, privacy: .public)")
          self.beginFetch(pages: [current], supplemental: true)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, self.generation == epoch else { return }
        self.probingPages.remove(page.credentialID)
      }
    }
  }
  private func beginFetch(pages requestedPages: [PlatformPageDescriptor]? = nil, supplemental: Bool = false) {
    guard !running else { return }
    let pending = waitingPages, due = nextRefreshAt
    cancel(); completed = 0; succeeded = 0
    if supplemental || requestedPages != nil { waitingPages = pending; nextRefreshAt = due }
    let first = Self.formatter.string(from: from.dateValue), last = Self.formatter.string(from: through.dateValue)
    guard first <= last else { summary.stringValue = "起始日期不能晚于结束日期"; render(); return }
    let pages = requestedPages ?? sources(), epoch = generation; total = pages.count; running = !pages.isEmpty
    for page in pages { names[page.credentialID] = page.displayName }
    fetchButton.title = running ? "停止" : "获取"
    for p in pages { statuses[p.credentialID] = savedAt[p.credentialID] == nil ? "查询中" : "查询中 · 展示上次结果" }
    updateProgress(); render()
    if pages.isEmpty { scheduleRefresh() }
    for page in pages {
      waitingPages[page.credentialID] = nil
      let view = page.webView, requestID = UUID().uuidString
      let account = expectedUsername(page.credentialID)
      queried.append(view)
      var finished = false
      let finish: ([String: Any]) -> Void = { [weak self, weak view] result in
        guard let self, self.generation == epoch, !finished else { return }
        finished = true; self.completed += 1
        if let view, self.expectedUsername(page.credentialID) == account,
          self.sources().contains(where: { $0.credentialID == page.credentialID && $0.webView === view && $0.startURL == page.startURL }),
          result["kind"] as? String == "ok", let family = result["family"] as? String, let contextID = result["contextID"] as? String,
          let list = result["reviewers"] as? [[String: Any]] {
          let parsed: [Row] = list.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String, let count = item["count"] as? Int, count > 0 else { return nil }
            return Row(target: PendingOrderRow(platformID: page.credentialID, platform: page.displayName, orderID: id, status: "",
              contextID: contextID, family: family, startDate: first, endDate: last, reviewerName: name), count: count)
          }
          self.rows.removeAll { $0.target.platformID == page.credentialID }
          self.rows += parsed; self.succeeded += 1
          let date = Date(); self.savedAt[page.credentialID] = date; self.cachedPlatforms.remove(page.credentialID)
          self.cache.put(WithdrawalReviewersCache.Entry(platformID: page.credentialID, sourceURL: page.startURL.absoluteString,
            account: account, startDate: first, endDate: last, family: family,
            people: parsed.map { WithdrawalReviewersCache.Person(id: $0.target.orderID, name: $0.target.reviewerName!, count: $0.count) }, savedAt: date))
          self.statuses[page.credentialID] = parsed.isEmpty ? "无人工审核记录" : "已获取 \(parsed.count) 人"
          Logger(subsystem: "com.local.sms-success-monitor", category: "WithdrawalReviewers").notice("Reviewer query for \(page.credentialID, privacy: .public): people=\(parsed.count)")
        } else {
          let prefix = self.savedAt[page.credentialID] == nil ? "未获取：" : "刷新失败，保留上次结果："
          let changedView = self.sources().contains { $0.credentialID == page.credentialID && $0.startURL == page.startURL && ($0.webView !== view || !Self.pageReady($0)) }
          let wait = result["waitForPage"] as? Bool == true || changedView
          if wait, self.expectedUsername(page.credentialID) == account {
            self.waitingPages[page.credentialID] = WaitingPage(sourceURL: page.startURL, account: account, start: first, end: last)
          }
          self.statuses[page.credentialID] = prefix + (wait ? "等待页面恢复，就绪后自动补查" : result["message"] as? String ?? "页面已变化或查询未完成")
          self.cachedPlatforms.insert(page.credentialID)
        }
        self.cache.putStatus(WithdrawalReviewersCache.QueryStatus(platformID: page.credentialID, sourceURL: page.startURL.absoluteString,
          account: account, startDate: first, endDate: last, message: self.statuses[page.credentialID] ?? "未获取", checkedAt: Date()))
        self.statuses[page.credentialID] = "\(Date().formatted(date: .omitted, time: .shortened)) · \(self.statuses[page.credentialID] ?? "")"
        self.running = self.completed < self.total; self.fetchButton.title = self.running ? "停止" : "获取"
        self.updateProgress(); self.render()
        if !self.running {
          self.queried = []
          if let target = self.navigationTarget {
            self.navigationTarget = nil
            if !self.cachedPlatforms.contains(target.platformID), let fresh = self.rows.first(where: {
              $0.target.platformID == target.platformID && $0.target.orderID == target.orderID && $0.target.reviewerName == target.reviewerName
            }) { self.openReviewer?(fresh.target) }
            else { self.finishNavigation(message: "未能确认当前人员记录，请查看平台状态后重试") }
          } else { self.scheduleRefresh() }
        }
      }
      guard Self.pageReady(page) else {
        finish(["waitForPage": true]); continue
      }
      let arguments: [String: Any] = ["expectedUsername": account,
        "allowNPG": allowsNPG(page), "requiredNPGPermission": "WITHDRAW_AUDIT_RECORD_LIST", "requestID": requestID,
        "startDate": first, "endDate": last]
      var totalArguments = arguments; totalArguments["totalsOnly"] = true
      view.callAsyncJavaScript(queryScript, arguments: totalArguments, in: nil, in: .page) { result in
        DispatchQueue.main.async {
          guard self.generation == epoch, !finished else { return }
          let payload = (try? result.get()) as? [String: Any] ?? ["message": "查询失败，请检查登录或网络"]
          guard payload["kind"] as? String == "ok", let count = payload["platformTotal"] as? Int, count >= 0,
            self.expectedUsername(page.credentialID) == account,
            self.sources().contains(where: { $0.credentialID == page.credentialID && $0.webView === view && $0.startURL == page.startURL }) else { finish(payload); return }
          self.savePlatformTotal(page, account: account, start: first, end: last, count: count)
          self.statuses[page.credentialID] = "总数已更新 · 正在获取人员"; self.render()
          view.callAsyncJavaScript(self.queryScript, arguments: arguments, in: nil, in: .page) { result in
            DispatchQueue.main.async { finish((try? result.get()) as? [String: Any] ?? ["message": "人员查询失败，保留平台总数"]) }
          }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 200) { [weak view] in
        guard !finished, self.generation == epoch else { return }
        view?.evaluateJavaScript("if(window.__smsReviewerRun==='\(requestID)'){window.__smsReviewerRun=null;window.__smsReviewerAbort?.abort()}", completionHandler: nil)
        finish(["message": "查询超时，未确认完整总数"])
      }
    }
  }
  private func savePlatformTotal(_ page: PlatformPageDescriptor, account: String, start: String, end: String, count: Int) {
    cache.putTotal(.init(platformID: page.credentialID, sourceURL: page.startURL.absoluteString, account: account,
      startDate: start, endDate: end, count: count, savedAt: Date()))
    if dateRange.0 == start && dateRange.1 == end { platformTotals[page.credentialID] = count }
  }
  func applyNavigationTotal(_ target: PendingOrderRow, count: Int, account: String, sourceURL: URL) {
    guard count >= 0, expectedUsername(target.platformID) == account,
      let page = sources().first(where: { $0.credentialID == target.platformID && $0.startURL == sourceURL }) else { return }
    if target.allReviewers {
      savePlatformTotal(page, account: account, start: target.startDate, end: target.endDate, count: count)
    } else if let name = target.reviewerName,
      let entry = cache.matching(platformID: target.platformID, sourceURL: sourceURL.absoluteString, account: account, start: target.startDate, end: target.endDate) {
      let people = entry.people.filter { $0.id != target.orderID } + [.init(id: target.orderID, name: name, count: count)]
      cache.put(.init(platformID: entry.platformID, sourceURL: entry.sourceURL, account: entry.account, startDate: entry.startDate,
        endDate: entry.endDate, family: entry.family, people: people, savedAt: entry.savedAt))
      if dateRange.0 == target.startDate && dateRange.1 == target.endDate {
        rows.removeAll { $0.target.platformID == target.platformID && $0.target.orderID == target.orderID }
        rows.append(Row(target: target, count: count))
      }
    }
    if dateRange.0 == target.startDate && dateRange.1 == target.endDate {
      let message = "\(target.allReviewers ? "平台总数" : "人员数量")已更新"
      cache.putStatus(.init(platformID: target.platformID, sourceURL: sourceURL.absoluteString, account: account,
        startDate: target.startDate, endDate: target.endDate, message: message, checkedAt: Date()))
      statuses[target.platformID] = "\(Date().formatted(date: .omitted, time: .shortened)) · \(message)"
      render()
    }
  }
  private func updateProgress() {
    summary.stringValue = "查询 \(completed)/\(total) 平台 · 成功 \(succeeded) · \(running ? "获取中" : "获取完成")"
      + " · 已有数据 \(savedAt.count)/\(sources().count) 平台"
      + (savedAt.keys.contains(where: { cachedPlatforms.contains($0) || statuses[$0]?.contains("上次结果") == true }) ? " · 含上次结果" : "")
      + (cache.writeFailed ? " · 本地保存失败" : "")
      + (waitingPages.isEmpty ? "" : " · 等待页面恢复 \(waitingPages.count) 平台")
  }
  private func render() {
    let isStatus = views.selectedSegment == 1
    table.tableColumns[1].title = isStatus ? "查询结果" : "审核人员名称"
    let all: [Row] = isStatus ? statuses.map { id, status in
      Row(target: PendingOrderRow(platformID: id, platform: names[id] ?? id, orderID: "", status: status,
        contextID: "", family: "", startDate: "", endDate: ""), count: platformTotals[id] ?? 0)
    } : rows
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = all.filter { query.isEmpty || "\($0.target.platform) \($0.target.reviewerName ?? $0.target.status)".localizedCaseInsensitiveContains(query) }
      .sorted { ($0.target.platform, $0.target.reviewerName ?? "") < ($1.target.platform, $1.target.reviewerName ?? "") }
    let totalCount = filtered.reduce(0) { $0 + $1.count }
    table.tableColumns[2].title = (isStatus ? !platformTotals.isEmpty : !rows.isEmpty) ? "审核订单总数（合计 \(totalCount.formatted())）" : "审核订单总数"
    table.tableColumns[2].headerToolTip = isStatus ? "各平台筛选后接口总条数之和；未获取的平台不计入" : "各人员筛选后接口总条数之和；不等于平台总条数"
    pageCount = max(1, (filtered.count + 9) / 10); pageIndex = min(pageIndex, pageCount - 1)
    displayed = Array(filtered.dropFirst(pageIndex * 10).prefix(10)); table.reloadData()
    previous.isEnabled = pageIndex > 0; next.isEnabled = pageIndex + 1 < pageCount
    pageLabel.stringValue = "共 \(filtered.count) 条 · 第 \(pageIndex + 1) / \(pageCount) 页 · 每页 10 条"
  }
  func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard displayed.indices.contains(row) else { return nil }
    let item = displayed[row], column = tableColumn?.identifier.rawValue
    if column == "platform", views.selectedSegment == 1 {
      let button = NSButton(title: item.target.platform, target: self, action: #selector(platformClicked(_:)))
      button.tag = row; button.isBordered = false; button.contentTintColor = .linkColor; button.alignment = .left
      button.toolTip = "打开 \(item.target.platform) 今天的提现审核记录，不限审核人员"; return button
    }
    if column == "count", item.target.reviewerName != nil {
      let button = NSButton(title: String(item.count), target: self, action: #selector(countClicked(_:)))
      button.tag = row; button.isBordered = false; button.contentTintColor = .linkColor; button.alignment = .left
      button.toolTip = "在 \(item.target.platform) 查询 \(item.target.reviewerName!) 的提现订单"; return button
    }
    let label = NSTextField(labelWithString: column == "platform" ? item.target.platform : column == "reviewer" ? item.target.reviewerName ?? item.target.status
      : platformTotals[item.target.platformID] != nil ? item.count.formatted() : "--")
    label.lineBreakMode = .byTruncatingTail; label.toolTip = label.stringValue; return label
  }
  @objc private func countClicked(_ button: NSButton) {
    guard displayed.indices.contains(button.tag), !navigating else { return }
    let target = displayed[button.tag].target
    maintainCache()
    guard rows.contains(where: { $0.target.platformID == target.platformID && $0.target.orderID == target.orderID }) else { return }
    cancel(preserveWaiting: true); navigating = true; from.isEnabled = false; through.isEnabled = false; fetchButton.isEnabled = false
    summary.stringValue = "正在打开 \(target.platform) 的审核记录"
    openReviewer?(PendingOrderRow(platformID: target.platformID, platform: target.platform, orderID: target.orderID, status: "",
      contextID: "", family: target.family, startDate: target.startDate, endDate: target.endDate, reviewerName: target.reviewerName))
  }
  @objc private func platformClicked(_ button: NSButton) {
    guard views.selectedSegment == 1, displayed.indices.contains(button.tag), !navigating else { return }
    let platform = displayed[button.tag].target, today = Self.formatter.string(from: Date())
    cancel(preserveWaiting: true); navigationTarget = nil; navigating = true
    from.isEnabled = false; through.isEnabled = false; fetchButton.isEnabled = false
    summary.stringValue = "正在打开 \(platform.platform) 今天的审核记录"
    openReviewer?(PendingOrderRow(platformID: platform.platformID, platform: platform.platform, orderID: "", status: "",
      contextID: "", family: "", startDate: today, endDate: today, allReviewers: true))
  }
  func finishNavigation(message: String) {
    navigating = false; from.isEnabled = true; through.isEnabled = true; fetchButton.isEnabled = true; summary.stringValue = message
    scheduleRefresh()
  }
  static func verifyLayoutAndManualFetch() -> Bool {
    guard WithdrawalReviewersCache.verifyPersistence() else { return false }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "SMSMonitor.ReviewersChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
    let cache = WithdrawalReviewersCache(url: directory.appendingPathComponent("cache.json"))
    let c = WithdrawalReviewersWindowController(cache: cache, defaults: defaults)
    defer { c.timer?.invalidate(); c.maintenanceTimer?.invalidate(); c.readinessTimer?.invalidate() }
    guard !c.running, c.rows.isEmpty, c.queried.isEmpty, c.summary.stringValue == "未获取",
      Self.formatter.string(from: c.from.dateValue) == Self.formatter.string(from: c.through.dateValue) else { return false }
    c.rows = (0..<21).map { n in Row(target: PendingOrderRow(platformID: "npg", platform: "NPG", orderID: "\(n)", status: "",
      contextID: "test", family: "NPG", startDate: "2026-10-10", endDate: "2026-10-10", reviewerName: "reviewer\(n)"), count: n + 1) }
    c.statuses = ["npg":"已获取"]
    c.render(); guard c.displayed.count == 10, c.pageCount == 3, c.table.tableColumns[2].title.contains("231") else { return false }
    c.nextClicked(); c.nextClicked(); guard c.displayed.count == 1, !c.next.isEnabled else { return false }
    c.search.stringValue = "reviewer20"; c.filterChanged(); guard c.displayed.count == 1, c.pageIndex == 0, c.table.tableColumns[2].title.contains("21") else { return false }
    c.dateChanged(); guard c.rows.isEmpty && !c.running && c.table.tableColumns.count == 3,
      c.autoRefresh.state == .on, c.refreshMinutes == 30 else { return false }
    let page = PlatformPageDescriptor(profileIdentifier: UUID(), credentialID: "npg", displayName: "NPG",
      startURL: URL(string: "https://example.invalid")!, webView: WKWebView())
    c.sources = { [page] }; c.expectedUsername = { _ in "owner" }
    cache.put(WithdrawalReviewersCache.Entry(platformID: "npg", sourceURL: page.startURL.absoluteString, account: "owner",
      startDate: c.dateRange.0, endDate: c.dateRange.1, family: "NPG", people: [.init(id: "1", name: "reviewer", count: 42)], savedAt: Date()))
    c.restoreCache(); c.search.stringValue = ""; c.filterChanged()
    guard c.rows.count == 1, c.rows[0].count == 42, c.cachedPlatforms.contains("npg"), !c.running,
      c.table.tableColumns[2].title.contains("42") else { return false }
    let missing = PlatformPageDescriptor(profileIdentifier: UUID(), credentialID: "missing", displayName: "Missing",
      startURL: URL(string: "https://other.invalid")!, webView: WKWebView())
    cache.putTotal(.init(platformID: "npg", sourceURL: page.startURL.absoluteString, account: "owner", startDate: c.dateRange.0,
      endDate: c.dateRange.1, count: 350, savedAt: Date()))
    c.sources = { [page, missing] }; c.restoreCache(); c.views.selectedSegment = 1; c.render()
    guard c.statuses.count == 2, c.summary.stringValue.contains("1/2"), c.displayed.count == 2,
      c.displayed.first(where: { $0.target.platformID == "npg" })?.count == 350,
      c.table.tableColumns[2].title.contains("350"),
      (c.tableView(c.table, viewFor: c.table.tableColumns[2], row: 0) as? NSTextField)?.stringValue == "--",
      (c.tableView(c.table, viewFor: c.table.tableColumns[2], row: 1) as? NSTextField)?.stringValue == "350" else { return false }
    var opened: PendingOrderRow?
    c.openReviewer = { opened = $0 }
    guard let platformButton = c.tableView(c.table, viewFor: c.table.tableColumns[0], row: 0) as? NSButton else { return false }
    c.from.dateValue = Date(timeIntervalSince1970: 0); c.through.dateValue = c.from.dateValue
    c.platformClicked(platformButton)
    guard opened?.platformID == "missing", opened?.allReviewers == true, opened?.reviewerName == nil,
      opened?.orderID == "", opened?.startDate == Self.formatter.string(from: Date()), opened?.endDate == opened?.startDate else { return false }
    c.finishNavigation(message: "test"); c.from.dateValue = Date(); c.through.dateValue = Date()
    c.sources = { [page] }; c.views.selectedSegment = 0; c.restoreCache()
    // An unavailable page must retain its cache, not count it twice or replace it with zero.
    c.beginFetch(); guard !c.running, c.rows.count == 1, c.rows[0].count == 42,
      c.statuses["npg"]?.contains("保留上次结果") == true, c.waitingPages.count == 1 else { return false }
    c.activated = true; c.scheduleRefresh()
    let originalDue = c.nextRefreshAt
    c.checkWaitingPages(); guard c.completed == 1, c.waitingPages.count == 1, c.queried.isEmpty else { return false }
    let recovered = PlatformPageDescriptor(profileIdentifier: page.profileIdentifier, credentialID: "npg", displayName: "NPG",
      startURL: page.startURL, webView: WKWebView())
    // Exercise replacement with a real WebKit document, without business network requests.
    recovered.webView.loadHTMLString("<html><body>ready</body></html>", baseURL: page.startURL)
    let deadline = Date().addingTimeInterval(15)
    while !Self.pageReady(recovered), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard Self.pageReady(recovered) else { return false }
    c.sources = { [recovered, missing] }
    c.queryScript = "return {kind:'ok',platformTotal:355,family:'NPG',contextID:requestID,reviewers:[{id:'1',name:'reviewer',count:7}]}"
    c.readinessScript = "return false"
    c.checkWaitingPages()
    while !c.probingPages.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard c.waitingPages.count == 1, c.rows[0].count == 42 else { return false }
    c.readinessScript = "return true"
    c.checkWaitingPages()
    while c.running || !c.probingPages.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard !c.running, c.total == 1, c.succeeded == 1, c.rows.count == 1, c.rows[0].count == 7,
      c.waitingPages.isEmpty, c.nextRefreshAt == originalDue, c.statuses["npg"]?.contains("已获取") == true,
      c.platformTotals["npg"] == 355 else { return false }
    let person = c.rows[0].target
    c.applyNavigationTotal(person, count: 12, account: "owner", sourceURL: page.startURL)
    guard c.rows[0].count == 12, c.platformTotals["npg"] == 355 else { return false }
    c.applyNavigationTotal(person, count: 999, account: "other", sourceURL: page.startURL)
    guard c.rows[0].count == 12 else { return false }
    c.checkWaitingPages(); guard c.succeeded == 1, c.nextRefreshAt == originalDue else { return false }
    c.sources = { [page] }; c.beginFetch(); guard c.waitingPages.count == 1 else { return false }
    c.cancel(preserveWaiting: true); guard c.waitingPages.count == 1 else { return false }
    c.cancel(); c.sources = { [recovered] }; c.checkWaitingPages()
    guard !c.running, c.waitingPages.isEmpty else { return false }
    c.sources = { [page] }; c.beginFetch(); c.restoreCache()
    guard c.waitingPages.count == 1, c.statuses["npg"]?.contains("上次查询") == true else { return false }
    c.expectedUsername = { _ in "other" }; c.maintainCache(); guard c.rows.isEmpty else { return false }
    c.activated = true; c.scheduleRefresh()
    guard let timer = c.timer, timer.fireDate.timeIntervalSinceNow > 1795 else { return false }
    c.intervalField.stringValue = "0"; c.intervalEdited(); guard c.refreshMinutes == 1 else { return false }
    c.intervalField.stringValue = "99999"; c.intervalEdited(); guard c.refreshMinutes == 1440 else { return false }
    c.intervalField.stringValue = "30"; c.intervalEdited()
    guard defaults.integer(forKey: Self.intervalKey) == 30 else { return false }
    c.running = true; c.scheduleRefresh(); guard c.timer == nil else { return false }
    c.running = false; c.navigating = true; c.scheduleRefresh(); guard c.timer == nil else { return false }
    c.navigating = false; c.scheduleRefresh(); c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    guard c.timer != nil else { return false }
    c.timer?.fire(); guard !c.running, c.completed == 1, c.timer != nil else { return false }
    c.autoRefresh.state = .off; c.refreshSettingsChanged()
    guard c.timer == nil, !defaults.bool(forKey: Self.autoKey) else { return false }
    c.fetchClicked(); guard c.completed == 1 else { return false }
    c.selectedDay = "2000-01-01"; c.maintainCache()
    return c.selectedDay == Self.formatter.string(from: Date()) && c.dateRange.0 == c.dateRange.1
  }
}
