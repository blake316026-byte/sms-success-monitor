import AppKit
import Foundation
import SMSMonitorCore
import WebKit

func isAttachmentResponse(_ navigationResponse: WKNavigationResponse) -> Bool {
  guard let response = navigationResponse.response as? HTTPURLResponse else { return false }
  return response.value(forHTTPHeaderField: "Content-Disposition")?
    .localizedCaseInsensitiveContains("attachment") == true
}

struct MonitoredPlatformPage {
  let configuration: MonitorConfiguration
  let webView: WKWebView
}

struct PlatformPageDescriptor {
  let profileIdentifier: UUID
  let credentialID: String
  let displayName: String
  let startURL: URL
  let webView: WKWebView
}

struct PlatformAutoLoginTarget {
  let credentialID: String
  let displayName: String
  let monitorID: String?
}

@available(macOS 11.3, *)
final class PlatformDownloadCoordinator: NSObject, WKDownloadDelegate {
  static let shared = PlatformDownloadCoordinator()

  private var destinations: [ObjectIdentifier: URL] = [:]

  func attach(_ download: WKDownload) {
    download.delegate = self
  }

  func download(
    _ download: WKDownload,
    decideDestinationUsing response: URLResponse,
    suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    let downloadsDirectory = FileManager.default.urls(
      for: .downloadsDirectory,
      in: .userDomainMask
    ).first
    guard let downloadsDirectory else {
      completionHandler(nil)
      return
    }
    let destination = Self.availableDestination(
      directory: downloadsDirectory,
      suggestedFilename: suggestedFilename
    )
    destinations[ObjectIdentifier(download)] = destination
    completionHandler(destination)
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let destination = destinations.removeValue(forKey: ObjectIdentifier(download)) else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([destination])
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    destinations.removeValue(forKey: ObjectIdentifier(download))
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "文件下载失败"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "知道了")
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  private static func availableDestination(directory: URL, suggestedFilename: String) -> URL {
    let rawName = (suggestedFilename as NSString).lastPathComponent
    let filename = rawName.isEmpty ? "download" : rawName
    let candidate = directory.appendingPathComponent(filename, isDirectory: false)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

    let extensionName = candidate.pathExtension
    let baseName = candidate.deletingPathExtension().lastPathComponent
    for index in 2...9_999 {
      let numberedName = extensionName.isEmpty
        ? "\(baseName) (\(index))"
        : "\(baseName) (\(index)).\(extensionName)"
      let numberedURL = directory.appendingPathComponent(numberedName, isDirectory: false)
      if !FileManager.default.fileExists(atPath: numberedURL.path) { return numberedURL }
    }
    return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)", isDirectory: false)
  }
}

private struct SavedPlatformPage: Codable {
  let id: UUID
  let monitorID: String?
  let name: String
  let startURL: URL
}

private struct SavedWorkspaceLayout: Codable {
  let pages: [SavedPlatformPage]
  let knownBuiltInIDs: [String]
}

private final class PlatformPageViewController: NSViewController, WKNavigationDelegate {
  let id: UUID
  let monitorID: String?
  let webView: WKWebView
  var pageName: String
  var startURL: URL
  var onNavigationStateChange: (() -> Void)?
  private var isPerformanceActive = false

  var isBuiltIn: Bool { monitorID != nil }
  var credentialID: String {
    monitorID ?? "custom-\(id.uuidString.lowercased())"
  }

  private var observations: [NSKeyValueObservation] = []

  init(
    id: UUID = UUID(),
    monitorID: String? = nil,
    name: String,
    startURL: URL,
    webView: WKWebView
  ) {
    self.id = id
    self.monitorID = monitorID
    self.pageName = name
    self.startURL = startURL
    self.webView = webView
    super.init(nibName: nil, bundle: nil)
    title = name
    if webView.navigationDelegate == nil {
      webView.navigationDelegate = self
    }

    observations = [
      webView.observe(\.url, options: [.new]) { [weak self] _, _ in
        self?.onNavigationStateChange?()
      },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
        self?.onNavigationStateChange?()
      },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
        self?.onNavigationStateChange?()
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        self?.onNavigationStateChange?()
        if self?.webView.isLoading == false {
          self?.applyPerformanceMode()
        }
      },
    ]
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 720))
    webView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      webView.topAnchor.constraint(equalTo: contentView.topAnchor),
      webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    view = contentView
  }

  func setPerformanceActive(_ active: Bool) {
    guard isPerformanceActive != active else {
      applyPerformanceMode()
      return
    }
    isPerformanceActive = active
    applyPerformanceMode()
  }

  private func applyPerformanceMode() {
    let active = isPerformanceActive
    if #available(macOS 11.0, *) {
      webView.setAllMediaPlaybackSuspended(!active, completionHandler: nil)
    }
    webView.callAsyncJavaScript(
      """
      const root = document.documentElement;
      if (!root) return false;
      let style = document.getElementById("sms-monitor-inactive-style");
      if (!style) {
        style = document.createElement("style");
        style.id = "sms-monitor-inactive-style";
        style.textContent = `
          html[data-sms-monitor-inactive="true"] *,
          html[data-sms-monitor-inactive="true"] *::before,
          html[data-sms-monitor-inactive="true"] *::after {
            animation-play-state: paused !important;
            transition: none !important;
            caret-color: transparent !important;
          }
        `;
        (document.head || root).appendChild(style);
      }
      root.dataset.smsMonitorInactive = active ? "false" : "true";
      for (const marquee of document.querySelectorAll("marquee")) {
        try {
          if (active) marquee.start(); else marquee.stop();
        } catch (_) {}
      }
      return true;
      """,
      arguments: ["active": active],
      in: nil,
      in: .page
    ) { _ in }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    if #available(macOS 11.3, *),
      (!navigationResponse.canShowMIMEType || isAttachmentResponse(navigationResponse))
    {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  @available(macOS 11.3, *)
  func webView(
    _ webView: WKWebView,
    navigationAction: WKNavigationAction,
    didBecome download: WKDownload
  ) {
    PlatformDownloadCoordinator.shared.attach(download)
  }

  @available(macOS 11.3, *)
  func webView(
    _ webView: WKWebView,
    navigationResponse: WKNavigationResponse,
    didBecome download: WKDownload
  ) {
    PlatformDownloadCoordinator.shared.attach(download)
  }
}

private final class WorkspaceTabViewController: NSTabViewController {
  var onSelectionChange: (() -> Void)?
  var onMoveTab: ((Int, Int) -> Void)?
  private var tabDragRecognizer: NSPanGestureRecognizer?
  private var draggedIndex: Int?

  override func viewDidAppear() {
    super.viewDidAppear()
    guard tabDragRecognizer == nil, let control = findSegmentedControl(in: view) else { return }
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:)))
    control.addGestureRecognizer(recognizer)
    tabDragRecognizer = recognizer
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    onSelectionChange?()
  }

  private func findSegmentedControl(in root: NSView) -> NSSegmentedControl? {
    if let control = root as? NSSegmentedControl,
      control.segmentCount == tabViewItems.count
    {
      return control
    }
    for subview in root.subviews {
      if let match = findSegmentedControl(in: subview) { return match }
    }
    return nil
  }

  @objc private func handleTabDrag(_ recognizer: NSPanGestureRecognizer) {
    guard let control = recognizer.view as? NSSegmentedControl,
      control.segmentCount == tabViewItems.count,
      control.segmentCount > 1
    else { return }
    switch recognizer.state {
    case .began:
      draggedIndex = segmentIndex(at: recognizer.location(in: control), control: control)
    case .changed:
      guard let source = draggedIndex,
        let target = segmentIndex(at: recognizer.location(in: control), control: control),
        source != target
      else { return }
      onMoveTab?(source, target)
      draggedIndex = target
    default:
      draggedIndex = nil
    }
  }

  private func segmentIndex(at point: NSPoint, control: NSSegmentedControl) -> Int? {
    guard control.bounds.contains(point) else { return nil }
    let estimatedWidths = (0..<control.segmentCount).map { index -> CGFloat in
      let configuredWidth = control.width(forSegment: index)
      if configuredWidth > 0 { return configuredWidth }
      let label = control.label(forSegment: index) ?? ""
      let labelWidth = (label as NSString).size(
        withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
      ).width
      return labelWidth + 32
    }
    let totalWidth = estimatedWidths.reduce(0, +)
    let scale = totalWidth > 0 ? control.bounds.width / totalWidth : 1
    var rightEdge: CGFloat = 0
    for (index, width) in estimatedWidths.enumerated() {
      rightEdge += width * scale
      if point.x <= rightEdge { return index }
    }
    return control.segmentCount - 1
  }
}

private final class WrappingTabBarView: NSView {
  var onSelect: ((Int) -> Void)?
  var onMove: ((Int, Int) -> Void)?
  var items: [NSTabViewItem] = [] { didSet { rebuildButtons() } }
  var selectedIndex = 0 { didSet { updateSelection() } }
  var onHeightChange: ((CGFloat) -> Void)?

  private var buttons: [NSButton] = []
  private var draggedIndex: Int?
  private var lastHeight: CGFloat = 0
  private let horizontalPadding: CGFloat = 8
  private let verticalPadding: CGFloat = 6
  private let spacing: CGFloat = 4
  private let buttonHeight: CGFloat = 28

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:))))
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:))))
  }

  private func rebuildButtons() {
    buttons.forEach { $0.removeFromSuperview() }
    buttons = items.enumerated().map { index, item in
      let button = NSButton(title: item.label, target: self, action: #selector(selectTab(_:)))
      button.tag = index
      button.image = item.image
      button.imagePosition = .imageLeading
      button.bezelStyle = .rounded
      button.font = .systemFont(ofSize: 12)
      button.toolTip = item.toolTip
      button.lineBreakMode = .byClipping
      addSubview(button)
      return button
    }
    updateSelection()
    needsLayout = true
  }

  func refresh() {
    for (index, button) in buttons.enumerated() where items.indices.contains(index) {
      button.title = items[index].label
      button.image = items[index].image
      button.toolTip = items[index].toolTip
    }
    updateSelection()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let usableWidth = max(1, bounds.width - horizontalPadding * 2)
    var x = horizontalPadding
    var y = verticalPadding
    for button in buttons {
      let titleWidth = (button.title as NSString).size(
        withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: 12)]
      ).width
      let imageWidth: CGFloat = button.image == nil ? 0 : 18
      let width = min(usableWidth, max(72, ceil(titleWidth + imageWidth + 24)))
      if x > horizontalPadding, x + width > bounds.width - horizontalPadding {
        x = horizontalPadding
        y += buttonHeight + spacing
      }
      button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
      x += width + spacing
    }
    let height = y + buttonHeight + verticalPadding
    if abs(height - lastHeight) > 0.5 {
      lastHeight = height
      onHeightChange?(height)
    }
  }

  @objc private func selectTab(_ sender: NSButton) {
    onSelect?(sender.tag)
  }

  @objc private func handleTabDrag(_ recognizer: NSPanGestureRecognizer) {
    guard buttons.count > 1 else { return }
    switch recognizer.state {
    case .began:
      draggedIndex = buttonIndex(at: recognizer.location(in: self), nearest: false)
    case .changed:
      guard let source = draggedIndex,
        let target = buttonIndex(at: recognizer.location(in: self), nearest: true),
        source != target
      else { return }
      onMove?(source, target)
      draggedIndex = target
    default:
      draggedIndex = nil
    }
  }

  private func buttonIndex(at point: NSPoint, nearest: Bool) -> Int? {
    if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) {
      return index
    }
    guard nearest, bounds.insetBy(dx: -24, dy: -24).contains(point) else { return nil }
    return buttons.indices.min { lhs, rhs in
      let left = buttons[lhs].frame
      let right = buttons[rhs].frame
      return hypot(point.x - left.midX, point.y - left.midY)
        < hypot(point.x - right.midX, point.y - right.midY)
    }
  }

  private func updateSelection() {
    for (index, button) in buttons.enumerated() {
      button.state = index == selectedIndex ? .on : .off
      button.contentTintColor = index == selectedIndex ? .controlAccentColor : .labelColor
    }
  }
}

private final class WorkspaceContainerController: NSViewController {
  let tabs: WorkspaceTabViewController
  let tabBar = WrappingTabBarView()
  private var tabBarHeight: NSLayoutConstraint?

  init(tabs: WorkspaceTabViewController) {
    self.tabs = tabs
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabs.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(tabs)
    root.addSubview(tabBar)
    root.addSubview(tabs.view)
    let height = tabBar.heightAnchor.constraint(equalToConstant: 40)
    tabBarHeight = height
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      tabBar.topAnchor.constraint(equalTo: root.topAnchor),
      height,
      tabs.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      tabs.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      tabs.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
      tabs.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    tabBar.onHeightChange = { [weak self] value in
      self?.tabBarHeight?.constant = value
    }
    view = root
  }
}

final class PlatformWorkspaceController: NSObject, NSToolbarDelegate, WKUIDelegate,
  NSSearchFieldDelegate
{
  let window: NSWindow
  var onAutoLoginSettings: ((PlatformAutoLoginTarget) -> Void)?
  var onSampleLimitSettings: (() -> Void)?
  var onPageAdded: ((PlatformPageDescriptor) -> Void)?
  var onPageUpdated: ((PlatformPageDescriptor) -> Void)?
  var onPageRemoved: ((String) -> Void)?
  var onPageOrderChanged: (([String]) -> Void)?
  var onSelectedPageChanged: ((String?) -> Void)?

  private enum ToolbarIdentifier {
    static let toolbar = NSToolbar.Identifier("SMSMonitorPlatformToolbar")
    static let back = NSToolbarItem.Identifier("SMSMonitorPlatformBack")
    static let forward = NSToolbarItem.Identifier("SMSMonitorPlatformForward")
    static let reload = NSToolbarItem.Identifier("SMSMonitorPlatformReload")
    static let clearCache = NSToolbarItem.Identifier("SMSMonitorPlatformClearCache")
    static let address = NSToolbarItem.Identifier("SMSMonitorPlatformAddress")
    static let find = NSToolbarItem.Identifier("SMSMonitorPlatformFind")
    static let autoLogin = NSToolbarItem.Identifier("SMSMonitorPlatformAutoLogin")
    static let sampleLimit = NSToolbarItem.Identifier("SMSMonitorPlatformSampleLimit")
    static let addPage = NSToolbarItem.Identifier("SMSMonitorPlatformAddPage")
    static let closePage = NSToolbarItem.Identifier("SMSMonitorPlatformClosePage")
    static let renamePage = NSToolbarItem.Identifier("SMSMonitorPlatformRenamePage")
  }

  private static let savedPagesKey = "SMSMonitorPlatformPages.v1"
  private static let savedLayoutKey = "SMSMonitorPlatformLayout.v2"

  private let defaultInitialURL: URL
  private var sampleLimit: Int
  private let tabController = WorkspaceTabViewController()
  private lazy var workspaceContainer = WorkspaceContainerController(tabs: tabController)
  private var pages: [PlatformPageViewController] = []
  private var knownBuiltInIDs: Set<String> = []
  private var addressField: NSTextField?
  private var findField: NSSearchField?
  private var findResultLabel: NSTextField?
  private var findNavigationControl: NSSegmentedControl?
  private var findRequestGeneration = 0
  private var backItem: NSToolbarItem?
  private var forwardItem: NSToolbarItem?
  private var reloadItem: NSToolbarItem?
  private var sampleLimitItem: NSToolbarItem?
  private var autoLoginItem: NSToolbarItem?
  private var closePageItem: NSToolbarItem?
  private var renamePageItem: NSToolbarItem?

  init(
    sampleLimit: Int,
    monitoredPages: [MonitoredPlatformPage],
    credentialStore _: LocalCredentialStore
  ) {
    precondition(!monitoredPages.isEmpty)
    self.defaultInitialURL = monitoredPages[0].configuration.targetURL
    self.sampleLimit = SampleLimitPolicy.normalize(sampleLimit)
    self.window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    super.init()

    configureWindow()
    for (index, descriptor) in monitoredPages.enumerated() {
      let page = PlatformPageViewController(
        monitorID: descriptor.configuration.id,
        name: descriptor.configuration.displayName,
        startURL: descriptor.configuration.targetURL,
        webView: descriptor.webView
      )
      descriptor.webView.uiDelegate = self
      addPage(page, select: index == 0)
    }
    knownBuiltInIDs = Set(monitoredPages.map(\.configuration.id))
    restoreWorkspaceLayout()
    updateWindowSubtitle()
    updateToolbar()
    applySelectedPagePerformanceMode()
  }

  func show(moduleID: String? = nil) {
    if let moduleID,
      let index = pages.firstIndex(where: { $0.credentialID == moduleID })
    {
      tabController.selectedTabViewItemIndex = index
    }
    if !window.isVisible {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    updateToolbar()
  }

  func updateMonitorState(moduleID: String, state: AppMonitorState) {
    guard let page = pages.first(where: { $0.credentialID == moduleID }) else { return }
    guard let item = tabController.tabViewItems.first(where: { $0.viewController === page }) else {
      return
    }
    item.toolTip = "\(page.pageName) · \(Self.stateDescription(state))"
    item.image = NSImage(
      systemSymbolName: Self.stateSymbol(state),
      accessibilityDescription: Self.stateDescription(state)
    )
    syncWrappingTabBar()
  }

  func updateSampleLimit(_ value: Int) {
    sampleLimit = SampleLimitPolicy.normalize(value)
    sampleLimitItem?.toolTip = "设置全部后台的监控样本条数（当前 \(sampleLimit) 条）"
    updateWindowSubtitle()
  }

  func focusFind() {
    show(moduleID: nil)
    guard let findField else { return }
    window.makeFirstResponder(findField)
    findField.selectText(nil)
    findInSelectedPage(backwards: false, advance: false)
  }

  func stopAll() {
    for page in pages {
      page.webView.stopLoading()
    }
  }

  func pageDescriptors() -> [PlatformPageDescriptor] {
    pages.map(Self.descriptor)
  }

  func refreshMonitorCount() {
    updateWindowSubtitle()
  }

  private func configureWindow() {
    tabController.tabStyle = .unspecified
    tabController.canPropagateSelectedChildViewControllerTitle = false
    tabController.onSelectionChange = { [weak self] in
      self?.syncWrappingTabBar()
      self?.updateToolbar()
      self?.findInSelectedPage(backwards: false, advance: false)
      self?.applySelectedPagePerformanceMode()
    }
    tabController.onMoveTab = { [weak self] source, target in
      self?.movePage(from: source, to: target)
    }

    workspaceContainer.tabBar.onSelect = { [weak self] index in
      guard let self, self.pages.indices.contains(index) else { return }
      self.tabController.selectedTabViewItemIndex = index
    }
    workspaceContainer.tabBar.onMove = { [weak self] source, target in
      self?.movePage(from: source, to: target)
    }
    window.contentViewController = workspaceContainer
    window.title = "短信后台工作台"
    updateWindowSubtitle()
    window.minSize = NSSize(width: 620, height: 520)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.toolbarStyle = .unified
    window.setFrameAutosaveName("SMSMonitorPlatformWindow")

    let toolbar = NSToolbar(identifier: ToolbarIdentifier.toolbar)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    window.toolbar = toolbar
  }

  private func syncWrappingTabBar() {
    workspaceContainer.tabBar.items = tabController.tabViewItems
    workspaceContainer.tabBar.selectedIndex = max(0, tabController.selectedTabViewItemIndex)
    workspaceContainer.tabBar.refresh()
  }

  private func updateWindowSubtitle() {
    window.subtitle =
      "\(pages.count) 个监控后台 · 样本 \(sampleLimit) 条 · 不同标签使用独立登录会话"
  }

  private func restoreWorkspaceLayout() {
    if let data = UserDefaults.standard.data(forKey: Self.savedLayoutKey),
      let layout = try? JSONDecoder().decode(SavedWorkspaceLayout.self, from: data)
    {
      let fixedPages = Dictionary(
        uniqueKeysWithValues: pages.compactMap { page in
          page.monitorID.map { ($0, page) }
        }
      )
      var orderedPages: [PlatformPageViewController] = []
      for savedPage in layout.pages {
        if let monitorID = savedPage.monitorID, let page = fixedPages[monitorID] {
          page.pageName = savedPage.name
          page.title = savedPage.name
          orderedPages.append(page)
        } else if savedPage.monitorID == nil {
          let page = makeAdditionalPage(
            id: savedPage.id,
            name: savedPage.name,
            startURL: savedPage.startURL
          )
          orderedPages.append(page)
        }
      }
      let known = Set(layout.knownBuiltInIDs)
      knownBuiltInIDs.formUnion(known)
      orderedPages.append(
        contentsOf: pages.filter {
          guard let monitorID = $0.monitorID else { return false }
          return !known.contains(monitorID)
        }
      )
      pages = orderedPages
      rebuildTabs()
      saveWorkspaceLayout()
      return
    }

    restoreLegacyAdditionalPages()
    saveWorkspaceLayout()
  }

  private func restoreLegacyAdditionalPages() {
    guard
      let data = UserDefaults.standard.data(forKey: Self.savedPagesKey),
      let savedPages = try? JSONDecoder().decode([SavedPlatformPage].self, from: data)
    else {
      return
    }

    for savedPage in savedPages.prefix(12) {
      createAdditionalPage(
        id: savedPage.id,
        name: savedPage.name,
        startURL: savedPage.startURL,
        select: false,
        persist: false
      )
    }
  }

  private func addPage(_ page: PlatformPageViewController, select: Bool) {
    page.onNavigationStateChange = { [weak self] in
      self?.updateToolbar()
    }
    pages.append(page)

    let tabItem = NSTabViewItem(identifier: page.monitorID ?? page.id.uuidString)
    tabItem.viewController = page
    tabItem.label = page.pageName
    tabItem.toolTip = "\(page.pageName) · 等待连接"
    tabController.addTabViewItem(tabItem)

    if select {
      tabController.selectedTabViewItemIndex = pages.count - 1
    }
    syncWrappingTabBar()
  }

  private func rebuildTabs() {
    while let item = tabController.tabViewItems.last {
      tabController.removeTabViewItem(item)
    }
    for page in pages {
      attachTab(for: page)
    }
    if !pages.isEmpty {
      tabController.selectedTabViewItemIndex = 0
    }
    syncWrappingTabBar()
  }

  private func attachTab(for page: PlatformPageViewController) {
    page.onNavigationStateChange = { [weak self] in self?.updateToolbar() }
    let item = NSTabViewItem(identifier: page.monitorID ?? page.id.uuidString)
    item.viewController = page
    item.label = page.pageName
    item.toolTip = "\(page.pageName) · 等待连接"
    tabController.addTabViewItem(item)
  }

  private func makeAdditionalPage(id: UUID, name: String, startURL: URL)
    -> PlatformPageViewController
  {
    let configuration = WKWebViewConfiguration()
    if #available(macOS 14.0, *) {
      configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
    } else {
      configuration.websiteDataStore = .nonPersistent()
    }
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 1180, height: 720),
      configuration: configuration
    )
    webView.uiDelegate = self
    return PlatformPageViewController(id: id, name: name, startURL: startURL, webView: webView)
  }

  private func createAdditionalPage(
    id: UUID = UUID(),
    name: String,
    startURL: URL,
    select: Bool,
    persist: Bool = true
  ) {
    let page = makeAdditionalPage(id: id, name: name, startURL: startURL)
    addPage(page, select: select)
    if select { ensureSelectedPageLoaded() }
    onPageAdded?(Self.descriptor(page))

    if persist {
      saveWorkspaceLayout()
    }
    updateWindowSubtitle()
  }

  private var selectedPage: PlatformPageViewController? {
    let index = tabController.selectedTabViewItemIndex
    guard pages.indices.contains(index) else { return nil }
    return pages[index]
  }

  var selectedCredentialID: String? {
    selectedPage?.credentialID
  }

  private func applySelectedPagePerformanceMode() {
    ensureSelectedPageLoaded()
    let activeID = selectedPage?.credentialID
    for page in pages {
      page.setPerformanceActive(page.credentialID == activeID)
    }
    onSelectedPageChanged?(activeID)
  }

  private func ensureSelectedPageLoaded() {
    guard let page = selectedPage, page.webView.url == nil, !page.webView.isLoading else {
      return
    }
    page.webView.load(URLRequest(url: page.startURL))
  }

  private func updateToolbar() {
    guard let page = selectedPage else {
      closePageItem?.isEnabled = false
      renamePageItem?.isEnabled = false
      autoLoginItem?.isEnabled = false
      return
    }
    addressField?.stringValue = page.webView.url?.absoluteString ?? page.startURL.absoluteString
    backItem?.isEnabled = page.webView.canGoBack
    forwardItem?.isEnabled = page.webView.canGoForward
    closePageItem?.isEnabled = true
    renamePageItem?.isEnabled = true
    autoLoginItem?.isEnabled = true

    let isLoading = page.webView.isLoading
    reloadItem?.image = NSImage(
      systemSymbolName: isLoading ? "xmark" : "arrow.clockwise",
      accessibilityDescription: isLoading ? "停止加载" : "刷新"
    )
    reloadItem?.toolTip = isLoading ? "停止加载" : "刷新当前页面"
  }

  private func saveWorkspaceLayout() {
    let savedPages = pages.map {
      SavedPlatformPage(
        id: $0.id,
        monitorID: $0.monitorID,
        name: $0.pageName,
        startURL: $0.startURL
      )
    }
    let layout = SavedWorkspaceLayout(
      pages: savedPages,
      knownBuiltInIDs: knownBuiltInIDs.sorted()
    )
    guard let data = try? JSONEncoder().encode(layout) else { return }
    UserDefaults.standard.set(data, forKey: Self.savedLayoutKey)
  }

  private static func normalizedURL(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard
      let components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    return components.url
  }

  private static func stateDescription(_ state: AppMonitorState) -> String {
    switch state {
    case .browserOnly:
      return "已登录，仅浏览"
    case .disabled:
      return "监控已停用"
    case .starting:
      return "等待连接"
    case .scanning:
      return "正在扫描"
    case .healthy(let metrics, _):
      return "正常 \(metrics.percentageText)"
    case .alert(let metrics, _):
      return "报警 \(metrics.percentageText)"
    case .authenticationRequired:
      return "需要登录"
    case .error:
      return "扫描异常"
    }
  }

  private static func stateSymbol(_ state: AppMonitorState) -> String {
    switch state {
    case .browserOnly:
      return "globe"
    case .disabled:
      return "pause.circle"
    case .starting:
      return "clock"
    case .scanning:
      return "arrow.triangle.2.circlepath"
    case .healthy:
      return "checkmark.circle"
    case .alert:
      return "exclamationmark.triangle"
    case .authenticationRequired:
      return "lock"
    case .error:
      return "wifi.exclamationmark"
    }
  }

  @objc private func goBack() {
    selectedPage?.webView.goBack()
  }

  @objc private func goForward() {
    selectedPage?.webView.goForward()
  }

  @objc private func reloadOrStop() {
    guard let webView = selectedPage?.webView else { return }
    if webView.isLoading {
      webView.stopLoading()
    } else {
      webView.reload()
    }
    updateToolbar()
  }

  @objc private func clearBrowserCache() {
    let cacheTypes: Set<String> = [
      WKWebsiteDataTypeDiskCache,
      WKWebsiteDataTypeMemoryCache,
      WKWebsiteDataTypeOfflineWebApplicationCache,
      WKWebsiteDataTypeServiceWorkerRegistrations,
    ]
    var storesByIdentifier: [ObjectIdentifier: WKWebsiteDataStore] = [:]
    for page in pages {
      let store = page.webView.configuration.websiteDataStore
      storesByIdentifier[ObjectIdentifier(store)] = store
    }
    let group = DispatchGroup()
    for store in storesByIdentifier.values {
      group.enter()
      store.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) {
        group.leave()
      }
    }
    window.subtitle = "正在清除网页缓存..."
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      for page in self.pages {
        page.webView.reloadFromOrigin()
      }
      self.window.subtitle = "网页缓存已清除，正在从源站重新加载"
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
        self?.updateWindowSubtitle()
      }
    }
  }

  @objc private func configureAutoLogin() {
    guard let page = selectedPage else { return }
    onAutoLoginSettings?(
      PlatformAutoLoginTarget(
        credentialID: page.credentialID,
        displayName: page.pageName,
        monitorID: page.monitorID
      )
    )
  }

  @objc private func configureSampleLimit() {
    onSampleLimitSettings?()
  }

  @objc private func navigateFindResult(_ sender: NSSegmentedControl) {
    findInSelectedPage(backwards: sender.selectedSegment == 0, advance: true)
  }

  private func findInSelectedPage(backwards: Bool, advance: Bool) {
    guard let webView = selectedPage?.webView, let findField else { return }
    let query = findField.stringValue
    findRequestGeneration += 1
    let generation = findRequestGeneration
    findNavigationControl?.isEnabled = !query.isEmpty
    guard !query.isEmpty else {
      findField.textColor = .labelColor
      findField.toolTip = "查找当前后台网页内容"
      findResultLabel?.stringValue = ""
      webView.callAsyncJavaScript(
        PageFindScript.body,
        arguments: ["query": "", "backwards": false, "advance": false],
        in: nil,
        in: .page
      ) { _ in }
      webView.find("", configuration: WKFindConfiguration()) { _ in }
      return
    }

    webView.callAsyncJavaScript(
      PageFindScript.body,
      arguments: ["query": query, "backwards": backwards, "advance": advance],
      in: nil,
      in: .page
    ) { [weak self, weak webView] result in
      guard let self, let webView, webView === self.selectedPage?.webView else { return }
      guard generation == self.findRequestGeneration, query == self.findField?.stringValue else {
        return
      }
      guard case .success(let value) = result,
        let payload = value as? [String: Any], payload["supported"] as? Bool == true
      else {
        self.findUsingWebKit(query, backwards: backwards, in: webView)
        return
      }
      let count = (payload["count"] as? NSNumber)?.intValue ?? 0
      let active = (payload["active"] as? NSNumber)?.intValue ?? 0
      self.updateFindStatus(active: active, count: count)
    }
  }

  private func findUsingWebKit(_ query: String, backwards: Bool, in webView: WKWebView) {
    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    configuration.caseSensitive = false
    configuration.wraps = true
    webView.find(query, configuration: configuration) { [weak self, weak webView] result in
      guard let self, let webView, webView === self.selectedPage?.webView else { return }
      guard query == self.findField?.stringValue else { return }
      self.findResultLabel?.stringValue = result.matchFound ? "1/?" : "0/0"
      self.findField?.textColor = result.matchFound ? .labelColor : .systemRed
      self.findField?.toolTip = result.matchFound ? "已找到匹配项" : "当前网页中未找到"
      self.findNavigationControl?.isEnabled = result.matchFound
    }
  }

  private func updateFindStatus(active: Int, count: Int) {
    let found = count > 0
    findResultLabel?.stringValue = "\(active)/\(count)"
    findField?.textColor = found ? .labelColor : .systemRed
    findField?.toolTip = found ? "已高亮全部 \(count) 个匹配项" : "当前网页中未找到"
    findNavigationControl?.isEnabled = found
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField, field === findField else { return }
    findInSelectedPage(backwards: false, advance: false)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === findField else { return false }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
      findInSelectedPage(backwards: backwards, advance: true)
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      findField?.stringValue = ""
      findInSelectedPage(backwards: false, advance: false)
      selectedPage?.webView.window?.makeFirstResponder(selectedPage?.webView)
      return true
    }
    return false
  }

  @objc private func navigateFromAddressField(_ sender: NSTextField) {
    guard let page = selectedPage else { return }
    guard let url = Self.normalizedURL(from: sender.stringValue) else {
      sender.stringValue = page.webView.url?.absoluteString ?? page.startURL.absoluteString
      showInvalidAddressAlert()
      return
    }

    if !page.isBuiltIn {
      page.startURL = url
      saveWorkspaceLayout()
      onPageUpdated?(Self.descriptor(page))
    }
    page.webView.load(URLRequest(url: url))
  }

  @objc private func addNewPage() {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "新增监控后台页面"
    alert.informativeText = "新页面使用独立登录会话，并自动加入短信成功率监控总览。"
    alert.addButton(withTitle: "创建页面")
    alert.addButton(withTitle: "取消")

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 82))
    let nameLabel = NSTextField(labelWithString: "页面名称")
    nameLabel.frame = NSRect(x: 0, y: 53, width: 76, height: 20)
    nameLabel.alignment = .right

    let customPageCount = pages.count(where: { !$0.isBuiltIn })
    let nameField = NSTextField(frame: NSRect(x: 88, y: 49, width: 342, height: 26))
    nameField.stringValue = "后台账号 \(customPageCount + 1)"
    nameField.placeholderString = "例如：代理 A"
    nameField.setAccessibilityLabel("页面名称")

    let addressLabel = NSTextField(labelWithString: "后台地址")
    addressLabel.frame = NSRect(x: 0, y: 13, width: 76, height: 20)
    addressLabel.alignment = .right

    let addressField = NSTextField(frame: NSRect(x: 88, y: 9, width: 342, height: 26))
    addressField.stringValue = defaultInitialURL.absoluteString
    addressField.placeholderString = "https://example.com/login"
    addressField.setAccessibilityLabel("后台地址")

    accessoryView.addSubview(nameLabel)
    accessoryView.addSubview(nameField)
    accessoryView.addSubview(addressLabel)
    accessoryView.addSubview(addressField)
    alert.accessoryView = accessoryView

    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      guard let url = Self.normalizedURL(from: addressField.stringValue) else {
        self.showInvalidAddressAlert()
        return
      }
      let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = trimmedName.isEmpty ? "后台账号 \(customPageCount + 1)" : trimmedName
      self.createAdditionalPage(name: name, startURL: url, select: true)
    }
  }

  @objc private func closeCurrentPage() {
    guard let page = selectedPage else { return }
    guard let item = tabController.tabViewItems.first(where: { $0.viewController === page }) else {
      return
    }

    let credentialID = page.credentialID
    onPageRemoved?(credentialID)
    page.webView.stopLoading()
    tabController.removeTabViewItem(item)
    pages.removeAll { $0 === page }
    saveWorkspaceLayout()
    onPageOrderChanged?(pages.map(\.credentialID))
    updateToolbar()
    updateWindowSubtitle()
    syncWrappingTabBar()
  }

  @objc private func renameCurrentPage() {
    guard let page = selectedPage else { return }
    let alert = NSAlert()
    alert.messageText = "修改页面名称"
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    let field = NSTextField(string: page.pageName)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
    alert.accessoryView = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      page.pageName = name
      if let item = self.tabController.tabViewItems.first(where: { $0.viewController === page }) {
        item.label = name
        item.toolTip = name
      }
      self.saveWorkspaceLayout()
      self.onPageUpdated?(Self.descriptor(page))
      self.updateToolbar()
      self.syncWrappingTabBar()
    }
  }

  private func showInvalidAddressAlert() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "后台地址无效"
    alert.informativeText = "请输入完整的 http 或 https 地址。"
    alert.addButton(withTitle: "知道了")
    alert.beginSheetModal(for: window)
  }

  private func toolbarButton(
    identifier: NSToolbarItem.Identifier,
    label: String,
    symbol: String,
    toolTip: String,
    action: Selector
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = toolTip
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.action = action
    return item
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      ToolbarIdentifier.back,
      ToolbarIdentifier.forward,
      ToolbarIdentifier.reload,
      ToolbarIdentifier.clearCache,
      .flexibleSpace,
      ToolbarIdentifier.address,
      ToolbarIdentifier.find,
      ToolbarIdentifier.sampleLimit,
      ToolbarIdentifier.autoLogin,
      ToolbarIdentifier.addPage,
      ToolbarIdentifier.closePage,
      ToolbarIdentifier.renamePage,
    ]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      ToolbarIdentifier.back,
      ToolbarIdentifier.forward,
      ToolbarIdentifier.reload,
      ToolbarIdentifier.clearCache,
      ToolbarIdentifier.address,
      .flexibleSpace,
      ToolbarIdentifier.find,
      ToolbarIdentifier.sampleLimit,
      ToolbarIdentifier.autoLogin,
      ToolbarIdentifier.addPage,
      ToolbarIdentifier.closePage,
      ToolbarIdentifier.renamePage,
    ]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case ToolbarIdentifier.back:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "后退",
        symbol: "chevron.left",
        toolTip: "返回上一页",
        action: #selector(goBack)
      )
      backItem = item
      return item

    case ToolbarIdentifier.forward:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "前进",
        symbol: "chevron.right",
        toolTip: "前往下一页",
        action: #selector(goForward)
      )
      forwardItem = item
      return item

    case ToolbarIdentifier.reload:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "刷新",
        symbol: "arrow.clockwise",
        toolTip: "刷新当前页面",
        action: #selector(reloadOrStop)
      )
      reloadItem = item
      return item

    case ToolbarIdentifier.clearCache:
      return toolbarButton(
        identifier: itemIdentifier,
        label: "清除缓存",
        symbol: "eraser",
        toolTip: "清除全部后台网页缓存并从源站重新加载（保留登录状态）",
        action: #selector(clearBrowserCache)
      )

    case ToolbarIdentifier.address:
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 470, height: 28))
      field.placeholderString = "输入后台地址"
      field.font = .systemFont(ofSize: 13)
      field.lineBreakMode = .byTruncatingMiddle
      field.target = self
      field.action = #selector(navigateFromAddressField(_:))
      field.setAccessibilityLabel("后台地址")
      addressField = field

      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "后台地址"
      item.paletteLabel = "后台地址"
      item.view = field
      return item

    case ToolbarIdentifier.autoLogin:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "自动登录",
        symbol: "key.fill",
        toolTip: "设置当前后台的本地自动登录",
        action: #selector(configureAutoLogin)
      )
      autoLoginItem = item
      return item

    case ToolbarIdentifier.find:
      let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 164, height: 28))
      field.placeholderString = "查找网页内容"
      field.font = .systemFont(ofSize: 12.5)
      field.delegate = self
      field.setAccessibilityLabel("查找当前后台网页内容")
      findField = field

      let resultLabel = NSTextField(labelWithString: "")
      resultLabel.alignment = .center
      resultLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
      resultLabel.textColor = .secondaryLabelColor
      resultLabel.setContentHuggingPriority(.required, for: .horizontal)
      resultLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
      resultLabel.setAccessibilityLabel("查找结果数量")
      findResultLabel = resultLabel

      let navigation = NSSegmentedControl(
        images: [
          NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上一个匹配项")
            ?? NSImage(),
          NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下一个匹配项")
            ?? NSImage(),
        ],
        trackingMode: .momentary,
        target: self,
        action: #selector(navigateFindResult(_:))
      )
      navigation.setWidth(27, forSegment: 0)
      navigation.setWidth(27, forSegment: 1)
      navigation.setToolTip("上一个匹配项", forSegment: 0)
      navigation.setToolTip("下一个匹配项", forSegment: 1)
      navigation.isEnabled = false
      findNavigationControl = navigation

      let stack = NSStackView(views: [field, resultLabel, navigation])
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = 4
      stack.frame = NSRect(x: 0, y: 0, width: 270, height: 28)

      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "查找"
      item.paletteLabel = "查找"
      item.toolTip = "查找当前后台网页内容（Command-F）"
      item.view = stack
      return item

    case ToolbarIdentifier.sampleLimit:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "样本条数",
        symbol: "number.circle",
        toolTip: "设置全部后台的监控样本条数（当前 \(sampleLimit) 条）",
        action: #selector(configureSampleLimit)
      )
      sampleLimitItem = item
      return item

    case ToolbarIdentifier.addPage:
      return toolbarButton(
        identifier: itemIdentifier,
        label: "新增页面",
        symbol: "plus",
        toolTip: "新增监控后台页面",
        action: #selector(addNewPage)
      )

    case ToolbarIdentifier.closePage:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "关闭页面",
        symbol: "xmark.circle",
        toolTip: "删除当前后台入口（保留本机登录资料）",
        action: #selector(closeCurrentPage)
      )
      item.isEnabled = selectedPage != nil
      closePageItem = item
      return item

    case ToolbarIdentifier.renamePage:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "重命名",
        symbol: "pencil",
        toolTip: "修改当前后台名称",
        action: #selector(renameCurrentPage)
      )
      item.isEnabled = selectedPage != nil
      renamePageItem = item
      return item

    default:
      return nil
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
    }
    return nil
  }

  private func movePage(from source: Int, to target: Int) {
    guard pages.indices.contains(source), pages.indices.contains(target), source != target else {
      return
    }
    let page = pages.remove(at: source)
    pages.insert(page, at: target)
    let item = tabController.tabViewItems[source]
    tabController.removeTabViewItem(item)
    tabController.insertTabViewItem(item, at: target)
    tabController.selectedTabViewItemIndex = target
    syncWrappingTabBar()
    saveWorkspaceLayout()
    onPageOrderChanged?(pages.map(\.credentialID))
  }

  private static func descriptor(_ page: PlatformPageViewController) -> PlatformPageDescriptor {
    PlatformPageDescriptor(
      profileIdentifier: page.id,
      credentialID: page.credentialID,
      displayName: page.pageName,
      startURL: page.startURL,
      webView: page.webView
    )
  }
}
