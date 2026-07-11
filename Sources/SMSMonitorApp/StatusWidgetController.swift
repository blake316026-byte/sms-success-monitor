import AppKit
import QuartzCore
import SMSMonitorCore

protocol StatusWidgetActions: AnyObject {
  func statusWidgetRequestedScan(moduleID: String?)
  func statusWidgetRequestedPlatformWindow(moduleID: String?)
  func statusWidgetRequestedMute()
  func statusWidgetRequestedQuit()
}

private enum MonitorColors {
  static let background = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.078, alpha: 0.98)
  static let surface = NSColor(calibratedRed: 0.085, green: 0.098, blue: 0.12, alpha: 1)
  static let track = NSColor.white.withAlphaComponent(0.11)
  static let primaryText = NSColor(calibratedWhite: 0.98, alpha: 1)
  static let secondaryText = NSColor(calibratedRed: 0.68, green: 0.71, blue: 0.76, alpha: 1)
  static let healthy = NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.45, alpha: 1)
  static let alert = NSColor(calibratedRed: 1, green: 0.22, blue: 0.30, alpha: 1)
  static let authentication = NSColor(calibratedRed: 1, green: 0.67, blue: 0.16, alpha: 1)
  static let unavailable = NSColor(calibratedRed: 0.49, green: 0.54, blue: 0.62, alpha: 1)
  static let scanning = NSColor(calibratedRed: 0.26, green: 0.63, blue: 1, alpha: 1)
}

private struct WidgetPresentation {
  let color: NSColor
  let primaryText: String
  let sampleText: String
  let statusText: String
  let footerText: String
  let footerSymbol: String
  let progress: CGFloat
  let isAlert: Bool
  let isScanning: Bool
}

private final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class GaugeView: NSView {
  private let fillView = NSView()
  private let trackLayer = CAShapeLayer()
  private let glowLayer = CAShapeLayer()
  private let progressLayer = CAShapeLayer()
  private let primaryLabel = NSTextField(labelWithString: "")
  private let sampleLabel = NSTextField(labelWithString: "")
  private var lastProgress: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false

    fillView.wantsLayer = true
    fillView.layer?.backgroundColor = MonitorColors.surface.cgColor
    addSubview(fillView)

    for shapeLayer in [glowLayer, trackLayer, progressLayer] {
      shapeLayer.fillColor = NSColor.clear.cgColor
      shapeLayer.lineCap = .round
      layer?.addSublayer(shapeLayer)
    }
    trackLayer.strokeColor = MonitorColors.track.cgColor
    trackLayer.lineWidth = 9
    glowLayer.lineWidth = 15
    glowLayer.opacity = 0.22
    progressLayer.lineWidth = 9

    configureLabel(
      primaryLabel,
      font: .monospacedDigitSystemFont(ofSize: 41, weight: .bold),
      color: MonitorColors.primaryText
    )
    configureLabel(
      sampleLabel,
      font: .systemFont(ofSize: 13, weight: .medium),
      color: MonitorColors.secondaryText
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    let ringRect = bounds.insetBy(dx: 11, dy: 11)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius = min(ringRect.width, ringRect.height) / 2
    let ringPath = CGMutablePath()
    ringPath.addArc(
      center: center,
      radius: radius,
      startAngle: -.pi / 2,
      endAngle: .pi * 1.5,
      clockwise: false
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.path = ringPath
    glowLayer.path = ringPath
    progressLayer.path = ringPath
    CATransaction.commit()

    let fillRect = bounds.insetBy(dx: 21, dy: 21)
    fillView.frame = fillRect
    fillView.layer?.cornerRadius = fillRect.width / 2
    primaryLabel.frame = NSRect(x: 1, y: 52, width: fillRect.width - 2, height: 47)
    sampleLabel.frame = NSRect(x: 5, y: 31, width: fillRect.width - 10, height: 20)
  }

  func update(presentation: WidgetPresentation) {
    primaryLabel.stringValue = presentation.primaryText
    if presentation.primaryText.contains("%") {
      let fontSize: CGFloat = presentation.primaryText.count >= 5 ? 31 : 39
      primaryLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
    } else {
      primaryLabel.font = .systemFont(ofSize: 24, weight: .bold)
    }
    sampleLabel.stringValue = presentation.sampleText

    progressLayer.strokeColor = presentation.color.cgColor
    glowLayer.strokeColor = presentation.color.withAlphaComponent(0.58).cgColor
    glowLayer.shadowColor = presentation.color.cgColor
    glowLayer.shadowOffset = .zero
    glowLayer.shadowRadius = presentation.isAlert ? 12 : 7
    glowLayer.shadowOpacity = presentation.isAlert ? 0.76 : 0.28
    fillView.layer?.backgroundColor =
      presentation.color.withAlphaComponent(
        presentation.isAlert ? 0.13 : 0.075
      ).cgColor

    let targetProgress = min(max(presentation.progress, 0), 1)
    let animation = CABasicAnimation(keyPath: "strokeEnd")
    animation.fromValue = progressLayer.presentation()?.strokeEnd ?? lastProgress
    animation.toValue = targetProgress
    animation.duration = 0.65
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    progressLayer.strokeEnd = targetProgress
    glowLayer.strokeEnd = targetProgress
    progressLayer.add(animation, forKey: "progress")
    glowLayer.add(animation, forKey: "progress")
    lastProgress = targetProgress

    progressLayer.removeAnimation(forKey: "scanPulse")
    if presentation.isScanning {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.35
      pulse.toValue = 1
      pulse.duration = 0.45
      pulse.autoreverses = true
      pulse.repeatCount = 2
      progressLayer.add(pulse, forKey: "scanPulse")
    }
  }

  func runAlertBurst() {
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1, 1.055, 0.99, 1.035, 1]
    scale.keyTimes = [0, 0.25, 0.48, 0.72, 1]
    scale.duration = 1.1
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer?.add(scale, forKey: "alarmScale")

    let flare = CAKeyframeAnimation(keyPath: "shadowOpacity")
    flare.values = [0.35, 1, 0.45, 1, 0.35]
    flare.keyTimes = [0, 0.2, 0.48, 0.72, 1]
    flare.duration = 1.15
    glowLayer.add(flare, forKey: "alarmFlare")
  }

  private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
    label.alignment = .center
    label.textColor = color
    label.font = font
    label.lineBreakMode = .byTruncatingTail
    fillView.addSubview(label)
  }
}

private final class StatusWidgetView: NSView {
  var onPrimaryAction: (() -> Void)?
  var onContextMenu: ((NSEvent) -> Void)?

  private let headerIcon = NSImageView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let statusPill = NSView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let gaugeView = GaugeView()
  private let footerView = NSView()
  private let footerIcon = NSImageView()
  private let footerLabel = NSTextField(labelWithString: "")
  private var alarmTimer: Timer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = MonitorColors.background.cgColor
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOffset = CGSize(width: 0, height: -7)
    layer?.shadowRadius = 16
    layer?.shadowOpacity = 0.45

    headerIcon.image = NSImage(
      systemSymbolName: "antenna.radiowaves.left.and.right",
      accessibilityDescription: "监控"
    )
    headerIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
    headerIcon.imageScaling = .scaleProportionallyDown
    addSubview(headerIcon)

    configureLabel(nameLabel, font: .systemFont(ofSize: 13, weight: .semibold))
    nameLabel.alignment = .left
    nameLabel.textColor = MonitorColors.primaryText

    statusPill.wantsLayer = true
    statusPill.layer?.cornerRadius = 7
    addSubview(statusPill)
    configureLabel(statusLabel, font: .systemFont(ofSize: 10.5, weight: .bold), parent: statusPill)

    addSubview(gaugeView)

    footerView.wantsLayer = true
    footerView.layer?.cornerRadius = 6
    footerView.layer?.borderWidth = 1
    addSubview(footerView)
    footerIcon.imageScaling = .scaleProportionallyDown
    footerView.addSubview(footerIcon)
    configureLabel(
      footerLabel, font: .systemFont(ofSize: 11.5, weight: .semibold), parent: footerView)
    footerLabel.alignment = .left

    toolTip = "单击查看详情；右键打开操作菜单；拖动可调整位置"
  }

  deinit {
    alarmTimer?.invalidate()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    headerIcon.frame = NSRect(x: 14, y: bounds.height - 31, width: 19, height: 19)
    nameLabel.frame = NSRect(x: 39, y: bounds.height - 33, width: 112, height: 22)
    statusPill.frame = NSRect(x: bounds.width - 72, y: bounds.height - 32, width: 58, height: 20)
    statusLabel.frame = statusPill.bounds
    gaugeView.frame = NSRect(x: (bounds.width - 158) / 2, y: 45, width: 158, height: 158)
    footerView.frame = NSRect(x: 14, y: 12, width: bounds.width - 28, height: 28)
    footerIcon.frame = NSRect(x: 10, y: 6, width: 16, height: 16)
    footerLabel.frame = NSRect(x: 33, y: 4, width: footerView.bounds.width - 42, height: 20)
  }

  override func mouseDown(with event: NSEvent) {
    onPrimaryAction?()
  }

  override func rightMouseDown(with event: NSEvent) {
    onContextMenu?(event)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  func update(displayName: String, presentation: WidgetPresentation) {
    nameLabel.stringValue = displayName
    nameLabel.font = .systemFont(
      ofSize: displayName.count > 12 ? 11.5 : 13,
      weight: .semibold
    )
    headerIcon.contentTintColor = presentation.color
    statusLabel.stringValue = presentation.statusText
    statusLabel.textColor = presentation.color
    statusPill.layer?.backgroundColor = presentation.color.withAlphaComponent(0.15).cgColor
    statusPill.layer?.borderColor = presentation.color.withAlphaComponent(0.38).cgColor
    statusPill.layer?.borderWidth = 1

    footerLabel.stringValue = presentation.footerText
    footerLabel.textColor =
      presentation.isAlert ? MonitorColors.primaryText : MonitorColors.secondaryText
    footerIcon.image = NSImage(
      systemSymbolName: presentation.footerSymbol,
      accessibilityDescription: presentation.statusText
    )
    footerIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    footerIcon.contentTintColor = presentation.color
    footerView.layer?.backgroundColor =
      presentation.color.withAlphaComponent(
        presentation.isAlert ? 0.19 : 0.075
      ).cgColor
    footerView.layer?.borderColor =
      presentation.color.withAlphaComponent(
        presentation.isAlert ? 0.56 : 0.18
      ).cgColor

    layer?.borderWidth = presentation.isAlert ? 2 : 1
    layer?.borderColor =
      presentation.color.withAlphaComponent(
        presentation.isAlert ? 0.72 : 0.20
      ).cgColor
    layer?.shadowColor = presentation.isAlert ? MonitorColors.alert.cgColor : NSColor.black.cgColor
    layer?.shadowRadius = presentation.isAlert ? 22 : 16
    layer?.shadowOpacity = presentation.isAlert ? 0.62 : 0.45
    gaugeView.update(presentation: presentation)
    setAccessibilityLabel("\(displayName)，\(presentation.statusText)，\(presentation.sampleText)")

    if presentation.isAlert {
      startAlarmAnimation()
    } else {
      stopAlarmAnimation()
    }
  }

  private func startAlarmAnimation() {
    guard alarmTimer == nil else { return }
    runAlarmBurst()
    let timer = Timer(timeInterval: 3.2, repeats: true) { [weak self] _ in
      self?.runAlarmBurst()
    }
    RunLoop.main.add(timer, forMode: .common)
    alarmTimer = timer
  }

  private func stopAlarmAnimation() {
    alarmTimer?.invalidate()
    alarmTimer = nil
    layer?.removeAnimation(forKey: "alarmShake")
    layer?.removeAnimation(forKey: "alarmBorder")
    statusPill.layer?.removeAnimation(forKey: "alarmBadge")
  }

  private func runAlarmBurst() {
    let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
    shake.values = [0, -7, 6, -5, 4, -2, 0]
    shake.keyTimes = [0, 0.14, 0.28, 0.43, 0.59, 0.76, 1]
    shake.duration = 0.62
    shake.timingFunction = CAMediaTimingFunction(name: .linear)
    layer?.add(shake, forKey: "alarmShake")

    let border = CAKeyframeAnimation(keyPath: "borderColor")
    border.values = [
      MonitorColors.alert.withAlphaComponent(0.5).cgColor,
      NSColor.white.withAlphaComponent(0.95).cgColor,
      MonitorColors.alert.cgColor,
      NSColor.white.withAlphaComponent(0.9).cgColor,
      MonitorColors.alert.withAlphaComponent(0.72).cgColor,
    ]
    border.keyTimes = [0, 0.2, 0.46, 0.72, 1]
    border.duration = 1.15
    layer?.add(border, forKey: "alarmBorder")

    let badge = CAKeyframeAnimation(keyPath: "opacity")
    badge.values = [0.62, 1, 0.68, 1]
    badge.keyTimes = [0, 0.25, 0.58, 1]
    badge.duration = 1.1
    statusPill.layer?.add(badge, forKey: "alarmBadge")
    footerView.layer?.add(badge, forKey: "alarmFooter")
    gaugeView.runAlertBurst()
  }

  private func configureLabel(
    _ label: NSTextField,
    font: NSFont,
    parent: NSView? = nil
  ) {
    label.alignment = .center
    label.textColor = MonitorColors.primaryText
    label.font = font
    label.lineBreakMode = .byTruncatingTail
    (parent ?? self).addSubview(label)
  }
}

private final class DetailPanelController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate
{
  weak var actions: StatusWidgetActions?

  private let tableView = NSTableView()
  private let alertSummary = NSTextField(labelWithString: "")
  private let healthySummary = NSTextField(labelWithString: "")
  private let authenticationSummary = NSTextField(labelWithString: "")
  private let errorSummary = NSTextField(labelWithString: "")
  private let coverageLabel = NSTextField(labelWithString: "")
  private let selectedNameLabel = NSTextField(labelWithString: "")
  private let selectedDetailLabel = NSTextField(labelWithString: "")
  private var snapshot = FleetMonitorSnapshot(modules: [])
  private var selectedModuleID: String?

  init(moduleCount: Int) {
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
      styleMask: [.titled, .closable, .utilityWindow, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "短信监控总览"
    window.subtitle = "\(moduleCount) 个后台 · 每分钟扫描最新 200 条"
    window.level = .floating
    window.minSize = NSSize(width: 700, height: 440)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("SMSMonitorFleetDetailWindow")
    super.init(window: window)
    buildContent()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(snapshot: FleetMonitorSnapshot, muteDescription: String?) {
    self.snapshot = snapshot
    if selectedModuleID == nil
      || !snapshot.modules.contains(where: { $0.configuration.id == selectedModuleID })
    {
      selectedModuleID = snapshot.focus?.configuration.id
    }

    alertSummary.stringValue = "报警 \(snapshot.alertCount)"
    healthySummary.stringValue = "正常 \(snapshot.healthyCount)"
    authenticationSummary.stringValue = "需登录 \(snapshot.authenticationCount)"
    errorSummary.stringValue = "异常 \(snapshot.errorCount)"
    let scannedCount = snapshot.alertCount + snapshot.healthyCount
    coverageLabel.stringValue =
      muteDescription ?? "已扫描 \(scannedCount)/\(snapshot.modules.count) · 阈值低于 50%"

    tableView.reloadData()
    if let selectedModuleID,
      let row = snapshot.modules.firstIndex(where: {
        $0.configuration.id == selectedModuleID
      })
    {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      tableView.scrollRowToVisible(row)
    }
    updateSelectedModule()
  }

  func select(moduleID: String?) {
    guard let moduleID,
      let row = snapshot.modules.firstIndex(where: { $0.configuration.id == moduleID })
    else { return }
    selectedModuleID = moduleID
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    updateSelectedModule()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    snapshot.modules.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard snapshot.modules.indices.contains(row), let tableColumn else { return nil }
    let module = snapshot.modules[row]
    let identifier = tableColumn.identifier
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier: identifier)
    guard let label = cell.textField else { return cell }

    label.stringValue = Self.cellText(identifier: identifier, module: module)
    label.textColor = Self.cellColor(identifier: identifier, state: module.state)
    label.alignment = identifier == .module ? .left : .center
    label.font =
      identifier == .module
      ? .systemFont(ofSize: 13, weight: .semibold)
      : identifier == .rate
        ? .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        : .systemFont(ofSize: 13)
    cell.setAccessibilityLabel(
      "\(module.configuration.displayName)，\(Self.stateText(module.state))"
    )
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard snapshot.modules.indices.contains(tableView.selectedRow) else { return }
    selectedModuleID = snapshot.modules[tableView.selectedRow].configuration.id
    updateSelectedModule()
  }

  @objc private func scanSelected() {
    actions?.statusWidgetRequestedScan(moduleID: selectedModuleID)
  }

  @objc private func scanAll() {
    actions?.statusWidgetRequestedScan(moduleID: nil)
  }

  @objc private func openSelected() {
    actions?.statusWidgetRequestedPlatformWindow(moduleID: selectedModuleID)
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let titleLabel = NSTextField(labelWithString: "全部后台")
    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.frame = NSRect(x: 20, y: 490, width: 160, height: 28)
    titleLabel.autoresizingMask = [.minYMargin]
    contentView.addSubview(titleLabel)

    coverageLabel.font = .systemFont(ofSize: 12.5)
    coverageLabel.textColor = .secondaryLabelColor
    coverageLabel.frame = NSRect(x: 20, y: 466, width: 360, height: 20)
    coverageLabel.autoresizingMask = [.width, .minYMargin]
    contentView.addSubview(coverageLabel)

    configureSummaryLabel(alertSummary, color: MonitorColors.alert)
    configureSummaryLabel(healthySummary, color: MonitorColors.healthy)
    configureSummaryLabel(authenticationSummary, color: MonitorColors.authentication)
    configureSummaryLabel(errorSummary, color: MonitorColors.unavailable)
    let summaries = NSStackView(views: [
      alertSummary,
      healthySummary,
      authenticationSummary,
      errorSummary,
    ])
    summaries.orientation = .horizontal
    summaries.spacing = 16
    summaries.alignment = .centerY
    summaries.frame = NSRect(x: 450, y: 484, width: 310, height: 24)
    summaries.autoresizingMask = [.minXMargin, .minYMargin]
    contentView.addSubview(summaries)

    let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
      (.module, "后台", 150),
      (.status, "状态", 82),
      (.rate, "成功率", 88),
      (.success, "成功 / 样本", 110),
      (.nonSuccess, "未成功", 78),
      (.updated, "最近扫描", 112),
    ]
    for (identifier, title, width) in columns {
      let column = NSTableColumn(identifier: identifier)
      column.title = title
      column.width = width
      column.minWidth = max(64, width - 30)
      tableView.addTableColumn(column)
    }
    tableView.delegate = self
    tableView.dataSource = self
    tableView.rowHeight = 34
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = false
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.doubleAction = #selector(openSelected)
    tableView.target = self

    let scrollView = NSScrollView(frame: NSRect(x: 20, y: 96, width: 740, height: 358))
    scrollView.autoresizingMask = [.width, .height]
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .bezelBorder
    contentView.addSubview(scrollView)

    let separator = NSBox(frame: NSRect(x: 20, y: 82, width: 740, height: 1))
    separator.boxType = .separator
    separator.autoresizingMask = [.width, .maxYMargin]
    contentView.addSubview(separator)

    selectedNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    selectedNameLabel.frame = NSRect(x: 20, y: 47, width: 300, height: 22)
    selectedNameLabel.autoresizingMask = [.width, .maxYMargin]
    contentView.addSubview(selectedNameLabel)

    selectedDetailLabel.font = .systemFont(ofSize: 12.5)
    selectedDetailLabel.textColor = .secondaryLabelColor
    selectedDetailLabel.frame = NSRect(x: 20, y: 22, width: 580, height: 20)
    selectedDetailLabel.autoresizingMask = [.width, .maxYMargin]
    contentView.addSubview(selectedDetailLabel)

    let scanAllButton = makeSymbolButton(
      symbol: "arrow.triangle.2.circlepath",
      toolTip: "立即扫描全部后台",
      action: #selector(scanAll)
    )
    scanAllButton.frame = NSRect(x: 644, y: 28, width: 34, height: 34)
    scanAllButton.autoresizingMask = [.minXMargin, .maxYMargin]
    contentView.addSubview(scanAllButton)

    let scanButton = makeSymbolButton(
      symbol: "arrow.clockwise",
      toolTip: "扫描选中后台",
      action: #selector(scanSelected)
    )
    scanButton.frame = NSRect(x: 684, y: 28, width: 34, height: 34)
    scanButton.autoresizingMask = [.minXMargin, .maxYMargin]
    contentView.addSubview(scanButton)

    let platformButton = makeSymbolButton(
      symbol: "globe",
      toolTip: "打开选中后台",
      action: #selector(openSelected)
    )
    platformButton.frame = NSRect(x: 724, y: 28, width: 34, height: 34)
    platformButton.autoresizingMask = [.minXMargin, .maxYMargin]
    contentView.addSubview(platformButton)
  }

  private func configureSummaryLabel(_ label: NSTextField, color: NSColor) {
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    label.textColor = color
    label.alignment = .center
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    cell.addSubview(label)
    cell.textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func makeSymbolButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage()
    let button = NSButton(image: image, target: self, action: action)
    button.bezelStyle = .texturedRounded
    button.toolTip = toolTip
    return button
  }

  private func updateSelectedModule() {
    guard let selectedModuleID,
      let module = snapshot.modules.first(where: {
        $0.configuration.id == selectedModuleID
      })
    else {
      selectedNameLabel.stringValue = ""
      selectedDetailLabel.stringValue = ""
      return
    }

    selectedNameLabel.stringValue =
      "\(module.configuration.displayName) · \(Self.stateText(module.state))"
    selectedNameLabel.textColor = StatusWidgetController.presentation(for: module.state).color
    selectedDetailLabel.stringValue = Self.detailText(module)
  }

  private static func cellText(
    identifier: NSUserInterfaceItemIdentifier,
    module: ModuleMonitorSnapshot
  ) -> String {
    switch identifier {
    case .module:
      return module.configuration.displayName
    case .status:
      return stateText(module.state)
    case .rate:
      return module.state.metrics?.percentageText ?? "--"
    case .success:
      guard let metrics = module.state.metrics else { return "-- / --" }
      return "\(metrics.successCount) / \(metrics.sampleCount)"
    case .nonSuccess:
      return module.state.metrics.map { String($0.nonSuccessCount) } ?? "--"
    case .updated:
      return dateText(module.state.scannedAt)
    default:
      return ""
    }
  }

  private static func cellColor(
    identifier: NSUserInterfaceItemIdentifier,
    state: AppMonitorState
  ) -> NSColor {
    if identifier == .status || identifier == .rate {
      return StatusWidgetController.presentation(for: state).color
    }
    return .labelColor
  }

  private static func stateText(_ state: AppMonitorState) -> String {
    switch state {
    case .starting:
      return "等待连接"
    case .scanning:
      return "扫描中"
    case .healthy:
      return "正常"
    case .alert:
      return "报警"
    case .authenticationRequired:
      return "需登录"
    case .error:
      return "异常"
    }
  }

  private static func detailText(_ module: ModuleMonitorSnapshot) -> String {
    if let metrics = module.state.metrics {
      return
        "成功 \(metrics.successCount)/\(metrics.sampleCount) · 未成功 \(metrics.nonSuccessCount) · 下次 \(dateText(module.nextScanAt))"
    }
    switch module.state {
    case .starting(let message), .authenticationRequired(let message), .error(let message, _):
      return message
    case .scanning:
      return "正在读取最新 200 条短信记录"
    case .healthy, .alert:
      return ""
    }
  }

  private static func dateText(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

extension NSUserInterfaceItemIdentifier {
  fileprivate static let module = NSUserInterfaceItemIdentifier("module")
  fileprivate static let status = NSUserInterfaceItemIdentifier("status")
  fileprivate static let rate = NSUserInterfaceItemIdentifier("rate")
  fileprivate static let success = NSUserInterfaceItemIdentifier("success")
  fileprivate static let nonSuccess = NSUserInterfaceItemIdentifier("nonSuccess")
  fileprivate static let updated = NSUserInterfaceItemIdentifier("updated")
}

final class StatusWidgetController: NSWindowController {
  weak var actions: StatusWidgetActions? {
    didSet { detailController.actions = actions }
  }

  private let widgetView: StatusWidgetView
  private let detailController: DetailPanelController
  private var currentSnapshot: FleetMonitorSnapshot
  private var appObservers: [NSObjectProtocol] = []
  private var workspaceObservers: [NSObjectProtocol] = []

  init(configurations: [MonitorConfiguration]) {
    precondition(!configurations.isEmpty)
    let widgetSize = NSSize(width: 228, height: 236)
    self.currentSnapshot = .initial(configurations: configurations)
    self.widgetView = StatusWidgetView(frame: NSRect(origin: .zero, size: widgetSize))
    self.detailController = DetailPanelController(moduleCount: configurations.count)

    let panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: widgetSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    panel.contentView = widgetView
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.worksWhenModal = true
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.setFrameAutosaveName("SMSMonitorWidgetWindow")
    panel.setContentSize(widgetSize)

    super.init(window: panel)

    widgetView.onPrimaryAction = { [weak self] in
      self?.toggleDetails()
    }
    widgetView.onContextMenu = { [weak self] event in
      self?.showContextMenu(for: event)
    }

    applyDefaultPositionIfNeeded()
    installAlwaysOnTopObservers()
    update(snapshot: currentSnapshot, muteDescription: nil)
  }

  deinit {
    for observer in appObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  func show() {
    ensureAlwaysOnTop()
  }

  func update(snapshot: FleetMonitorSnapshot, muteDescription: String?) {
    currentSnapshot = snapshot

    guard let focus = snapshot.focus else { return }
    let basePresentation = Self.presentation(for: focus.state)
    let presentation = Self.aggregatePresentation(
      basePresentation,
      snapshot: snapshot,
      focus: focus
    )
    widgetView.update(
      displayName: focus.configuration.displayName,
      presentation: presentation
    )
    detailController.update(snapshot: snapshot, muteDescription: muteDescription)
    NSApp.applicationIconImage = StatusIconRenderer.render(
      displayName: focus.configuration.displayName,
      presentation: presentation
    )
    ensureAlwaysOnTop()
  }

  fileprivate static func presentation(for state: AppMonitorState) -> WidgetPresentation {
    switch state {
    case .starting:
      return WidgetPresentation(
        color: MonitorColors.unavailable,
        primaryText: "启动中",
        sampleText: "等待首次扫描",
        statusText: "正在启动",
        footerText: "正在建立安全连接",
        footerSymbol: "clock.fill",
        progress: 0,
        isAlert: false,
        isScanning: false
      )
    case .scanning(let metrics):
      return WidgetPresentation(
        color: MonitorColors.scanning,
        primaryText: metrics?.percentageText ?? "扫描中",
        sampleText: metrics.map { "样本 \($0.sampleCount)" } ?? "读取最新 200 条",
        statusText: "正在扫描",
        footerText: metrics.map { "正在更新 · 样本 \($0.sampleCount)" } ?? "正在读取最新 200 条",
        footerSymbol: "arrow.triangle.2.circlepath",
        progress: CGFloat(metrics?.successRate ?? 0),
        isAlert: false,
        isScanning: true
      )
    case .healthy(let metrics, _):
      return WidgetPresentation(
        color: MonitorColors.healthy,
        primaryText: metrics.percentageText,
        sampleText: "样本 \(metrics.sampleCount)",
        statusText: "正常",
        footerText: "成功 \(metrics.successCount)   未成功 \(metrics.nonSuccessCount)",
        footerSymbol: "checkmark.circle.fill",
        progress: CGFloat(metrics.successRate),
        isAlert: false,
        isScanning: false
      )
    case .alert(let metrics, _):
      return WidgetPresentation(
        color: MonitorColors.alert,
        primaryText: metrics.percentageText,
        sampleText: "样本 \(metrics.sampleCount)",
        statusText: "报警",
        footerText: "低于 50% · 成功 \(metrics.successCount)/\(metrics.sampleCount)",
        footerSymbol: "exclamationmark.triangle.fill",
        progress: CGFloat(metrics.successRate),
        isAlert: true,
        isScanning: false
      )
    case .authenticationRequired:
      return WidgetPresentation(
        color: MonitorColors.authentication,
        primaryText: "需登录",
        sampleText: "打开平台窗口",
        statusText: "登录失效",
        footerText: "点击查看详情并重新登录",
        footerSymbol: "lock.fill",
        progress: 0,
        isAlert: false,
        isScanning: false
      )
    case .error:
      return WidgetPresentation(
        color: MonitorColors.unavailable,
        primaryText: "连接异常",
        sampleText: "单击查看详情",
        statusText: "扫描异常",
        footerText: "等待下一次自动重试",
        footerSymbol: "wifi.exclamationmark",
        progress: 0,
        isAlert: false,
        isScanning: false
      )
    }
  }

  private static func aggregatePresentation(
    _ presentation: WidgetPresentation,
    snapshot: FleetMonitorSnapshot,
    focus: ModuleMonitorSnapshot
  ) -> WidgetPresentation {
    var statusText = presentation.statusText
    var footerText = presentation.footerText

    if focus.state.isAlert {
      statusText = snapshot.alertCount > 1 ? "报警 \(snapshot.alertCount)" : "报警"
      if let metrics = focus.state.metrics {
        footerText = "最低 · 成功 \(metrics.successCount)/\(metrics.sampleCount)"
      }
    } else if focus.state.requiresAuthentication, snapshot.authenticationCount > 1 {
      statusText = "待登录 \(snapshot.authenticationCount)"
    } else if focus.state.isError, snapshot.errorCount > 1 {
      statusText = "异常 \(snapshot.errorCount)"
    }

    return WidgetPresentation(
      color: presentation.color,
      primaryText: presentation.primaryText,
      sampleText: presentation.sampleText,
      statusText: statusText,
      footerText: footerText,
      footerSymbol: presentation.footerSymbol,
      progress: presentation.progress,
      isAlert: presentation.isAlert,
      isScanning: presentation.isScanning
    )
  }

  private func toggleDetails() {
    guard let detailWindow = detailController.window else { return }
    if detailWindow.isVisible {
      detailWindow.orderOut(nil)
    } else {
      detailController.select(moduleID: currentSnapshot.focus?.configuration.id)
      detailWindow.center()
      detailController.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func showContextMenu(for event: NSEvent) {
    let menu = NSMenu()
    menu.addItem(withTitle: "立即扫描全部后台", action: #selector(scanNow), keyEquivalent: "r")
      .target = self
    menu.addItem(withTitle: "打开后台工作台", action: #selector(openPlatform), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "静音 10 分钟", action: #selector(mute), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
    let point = widgetView.convert(event.locationInWindow, from: nil)
    menu.popUp(positioning: nil, at: point, in: widgetView)
  }

  @objc private func scanNow() {
    actions?.statusWidgetRequestedScan(moduleID: nil)
  }

  @objc private func openPlatform() {
    actions?.statusWidgetRequestedPlatformWindow(moduleID: currentSnapshot.focus?.configuration.id)
  }

  @objc private func mute() {
    actions?.statusWidgetRequestedMute()
  }

  @objc private func quit() {
    actions?.statusWidgetRequestedQuit()
  }

  private func applyDefaultPositionIfNeeded() {
    guard let panel = window,
      UserDefaults.standard.object(forKey: "NSWindow Frame SMSMonitorWidgetWindow") == nil
    else {
      return
    }
    guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
    let origin = NSPoint(x: visibleFrame.minX + 18, y: visibleFrame.minY + 18)
    panel.setFrameOrigin(origin)
  }

  private func installAlwaysOnTopObservers() {
    let appCenter = NotificationCenter.default
    for name in [
      NSApplication.didResignActiveNotification,
      NSApplication.didBecomeActiveNotification,
      NSApplication.didChangeScreenParametersNotification,
    ] {
      let observer = appCenter.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        self?.ensureAlwaysOnTop()
      }
      appObservers.append(observer)
    }

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let spaceObserver = workspaceCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.ensureAlwaysOnTop()
    }
    workspaceObservers.append(spaceObserver)
  }

  private func ensureAlwaysOnTop() {
    guard let panel = window else { return }
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.orderFrontRegardless()
  }
}

private enum StatusIconRenderer {
  static func render(displayName: String, presentation: WidgetPresentation) -> NSImage {
    let size = NSSize(width: 512, height: 512)
    let image = NSImage(size: size)
    image.lockFocus()

    MonitorColors.background.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472),
      xRadius: 54,
      yRadius: 54
    ).fill()

    let fillRect = NSRect(x: 96, y: 96, width: 320, height: 320)
    presentation.color.withAlphaComponent(presentation.isAlert ? 0.17 : 0.09).setFill()
    NSBezierPath(ovalIn: fillRect).fill()

    let ringRect = NSRect(x: 74, y: 74, width: 364, height: 364)
    MonitorColors.track.setStroke()
    let track = NSBezierPath(ovalIn: ringRect)
    track.lineWidth = 25
    track.stroke()

    if let context = NSGraphicsContext.current?.cgContext, presentation.progress > 0 {
      context.saveGState()
      context.setStrokeColor(presentation.color.cgColor)
      context.setLineWidth(25)
      context.setLineCap(.round)
      if presentation.isAlert {
        context.setShadow(offset: .zero, blur: 24, color: presentation.color.cgColor)
      }
      context.addArc(
        center: CGPoint(x: 256, y: 256),
        radius: 182,
        startAngle: -.pi / 2,
        endAngle: -.pi / 2 + (.pi * 2 * presentation.progress),
        clockwise: false
      )
      context.strokePath()
      context.restoreGState()
    }

    drawCentered(
      displayName,
      in: NSRect(x: 74, y: 356, width: 364, height: 48),
      fontSize: 34,
      weight: .semibold
    )
    drawCentered(
      presentation.primaryText,
      in: NSRect(x: 72, y: 204, width: 368, height: 118),
      fontSize: presentation.primaryText.contains("%") ? 88 : 57,
      weight: .bold,
      monospacedDigits: presentation.primaryText.contains("%")
    )
    drawCentered(
      presentation.sampleText,
      in: NSRect(x: 86, y: 164, width: 340, height: 42),
      fontSize: 30,
      weight: .medium
    )
    drawCentered(
      presentation.statusText,
      in: NSRect(x: 116, y: 104, width: 280, height: 38),
      fontSize: 25,
      weight: .bold,
      color: presentation.color
    )

    image.unlockFocus()
    return image
  }

  private static func drawCentered(
    _ text: String,
    in rect: NSRect,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    monospacedDigits: Bool = false,
    color: NSColor = MonitorColors.primaryText
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font =
      monospacedDigits
      ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
      : NSFont.systemFont(ofSize: fontSize, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
    (text as NSString).draw(in: rect, withAttributes: attributes)
  }
}
