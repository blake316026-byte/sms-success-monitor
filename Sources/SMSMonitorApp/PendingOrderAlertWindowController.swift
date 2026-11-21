import AppKit

final class PendingOrderAlertWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
  private let service: PendingOrderAlertService
  private let enabled = NSButton(checkboxWithTitle: "启用 TG 挂单报警", target: nil, action: nil)
  private let minutes = NSTextField(string: "20")
  private let days = NSTextField(string: "7")
  private let token = NSSecureTextField(string: "")
  private let group = NSTextField(string: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let table = NSTableView()
  private let views = NSSegmentedControl(labels: ["发送记录（24 小时）", "平台查询状态"], trackingMode: .selectOne, target: nil, action: nil)
  private var rows: [[String]] = []
  private var platformIDs: [String] = []
  private var displayedView = -1
  private var selectionError = ""
  private var timer: Timer?
  init(service: PendingOrderAlertService) {
    self.service = service
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 570),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "提现挂单 TG 报警"; window.minSize = NSSize(width: 760, height: 500)
    window.isReleasedWhenClosed = false
    super.init(window: window); window.delegate = self
    let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    window.contentView = content
    let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
    save.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "保存设置")
    save.imagePosition = .imageLeading; save.toolTip = "保存设置"
    save.bezelStyle = .rounded
    token.placeholderString = "已保存时留空保持不变"; token.setAccessibilityLabel("机器人 Token")
    group.placeholderString = "例如 -1001234567890"; group.setAccessibilityLabel("TG 群 ID")
    minutes.setAccessibilityLabel("报警分钟数"); days.setAccessibilityLabel("查询天数")
    for field in [minutes, days] {
      let formatter = NumberFormatter(); formatter.numberStyle = .none; formatter.allowsFloats = false; formatter.minimum = 1
      field.formatter = formatter; field.alignment = .right; field.widthAnchor.constraint(equalToConstant: 70).isActive = true
    }
    let settings = NSStackView(); settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 14
    let header = NSStackView(views: [enabled, NSTextField(labelWithString: "超过"), minutes, NSTextField(labelWithString: "分钟"), save]); header.spacing = 10
    settings.addArrangedSubview(header)
    for (title, field) in [("机器人 Token", token as NSTextField), ("TG 群 ID", group)] {
      let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 105).isActive = true
      let row = NSStackView(views: [label, field]); row.spacing = 10
      field.widthAnchor.constraint(equalToConstant: 440).isActive = true; settings.addArrangedSubview(row)
    }
    let range = NSStackView(views: [NSTextField(labelWithString: "查询范围：全部平台 · 近"), days, NSTextField(labelWithString: "天 · 每个平台查询间隔 ≥ 60 秒")]); range.spacing = 8
    settings.addArrangedSubview(range)
    let policy = NSTextField(labelWithString: "北京时间每天每单最多一次 · 发送待确认不重发 · 仅本机发送")
    policy.textColor = .secondaryLabelColor; policy.font = .systemFont(ofSize: 12); settings.addArrangedSubview(policy)
    status.font = .systemFont(ofSize: 12); status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    views.selectedSegment = 0; views.target = self; views.action = #selector(refresh)
    let selection = NSTableColumn(identifier: .init("selected")); selection.title = "TG 报警"
    selection.width = 70; selection.minWidth = 70; selection.maxWidth = 70; table.addTableColumn(selection)
    for (id, title, width) in [("0", "平台", 130.0), ("1", "订单号", 180.0), ("2", "发送时间（北京时间）", 190.0), ("3", "结果", 280.0)] {
      let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = 100; table.addTableColumn(column)
    }
    table.dataSource = self; table.delegate = self; table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    for view in [settings, status, views, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
    NSLayoutConstraint.activate([
      settings.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), settings.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      settings.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
      status.topAnchor.constraint(equalTo: settings.bottomAnchor, constant: 12), status.leadingAnchor.constraint(equalTo: settings.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      views.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12), views.leadingAnchor.constraint(equalTo: settings.leadingAnchor),
      scroll.topAnchor.constraint(equalTo: views.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: settings.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
    ])
  }
  required init?(coder: NSCoder) { nil }
  func present() {
    selectionError = ""
    enabled.state = service.settings.enabled ? .on : .off; minutes.integerValue = service.settings.minutes
    days.integerValue = service.settings.lookbackDays; group.stringValue = service.settings.chatID; token.stringValue = ""
    token.placeholderString = service.settings.token.isEmpty ? "机器人 Token" : "已保存，留空保持不变"
    refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
  }
  func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; token.stringValue = "" }
  @objc private func saveSettings() {
    var next = service.settings
    next.enabled = enabled.state == .on; next.minutes = minutes.integerValue; next.lookbackDays = days.integerValue
    next.chatID = group.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.stringValue.isEmpty { next.token = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    do {
      try next.validate()
      if next.enabled && (next != service.settings) {
        let alert = NSAlert(); alert.messageText = "启用真实群报警？"
        alert.informativeText = "保存后会向该群发送超时提现订单。请只在一台电脑、一个客户端中启用；不同客户端不共享提醒记录。关闭本设置窗口不停止报警。发送结果不明当天不重发，次日仍未处理可再次提醒。"
        alert.addButton(withTitle: "启用并保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
      }
      try service.configure(next); token.stringValue = ""; refresh()
    } catch { status.stringValue = error.localizedDescription }
  }
  @objc private func refresh() {
    let selected = service.sources().filter { service.isSelected($0.credentialID) }.count
    status.stringValue = selectionError.isEmpty ? service.message + " · 已勾选 \(selected)/\(service.sources().count) 平台" : selectionError
    let platformView = views.selectedSegment == 1
    if displayedView != views.selectedSegment {
      displayedView = views.selectedSegment
      table.tableColumn(withIdentifier: .init("selected"))?.isHidden = !platformView
      for id in ["1", "2"] { table.tableColumn(withIdentifier: .init(id))?.isHidden = platformView }
      table.tableColumn(withIdentifier: .init("0"))?.width = platformView ? 190 : 130
      table.tableColumn(withIdentifier: .init("3"))?.title = platformView ? "查询结果" : "结果"
      if let scroll = table.enclosingScrollView {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
      }
    }
    if views.selectedSegment == 0 {
      platformIDs = []
      rows = service.records.map { [$0.platform, $0.orderID, PendingOrderTiming.formatter.string(from: $0.at), $0.state] }
    } else {
      let pages = service.sources(); platformIDs = pages.map(\.credentialID)
      rows = pages.map { [$0.displayName, "", "", (service.statuses[$0.credentialID] ?? "未查询") + (service.isSelected($0.credentialID) ? "" : " · 不发送 TG")] }
    }
    table.reloadData()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  @objc private func selectionChanged(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    do { try service.selectPlatform(id, selected: sender.state == .on); selectionError = "" }
    catch { selectionError = error.localizedDescription }
    refresh()
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    if tableColumn?.identifier.rawValue == "selected" {
      guard platformIDs.indices.contains(row) else { return nil }
      let id = platformIDs[row], button = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectionChanged(_:)))
      button.identifier = .init(id); button.state = service.isSelected(id) ? .on : .off
      button.toolTip = "是否向 TG 发送此平台的挂单报警"; button.setAccessibilityLabel(rows[row][0] + " TG 报警")
      return button
    }
    guard rows.indices.contains(row), let i = Int(tableColumn?.identifier.rawValue ?? ""), rows[row].indices.contains(i) else { return nil }
    let field = NSTextField(labelWithString: rows[row][i]); field.lineBreakMode = .byTruncatingTail; field.toolTip = rows[row][i]
    return field
  }
}
