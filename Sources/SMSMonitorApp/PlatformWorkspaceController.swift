import AppKit
import Foundation
import SMSMonitorCore
import WebKit

struct MonitoredPlatformPage {
  let configuration: MonitorConfiguration
  let webView: WKWebView
}

private struct SavedPlatformPage: Codable {
  let id: UUID
  let name: String
  let startURL: URL
}

private final class PlatformPageViewController: NSViewController {
  let id: UUID
  let monitorID: String?
  let webView: WKWebView
  var pageName: String
  var startURL: URL
  var onNavigationStateChange: (() -> Void)?

  var isMonitored: Bool { monitorID != nil }

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
}

private final class WorkspaceTabViewController: NSTabViewController {
  var onSelectionChange: (() -> Void)?

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    onSelectionChange?()
  }
}

final class PlatformWorkspaceController: NSObject, NSToolbarDelegate, WKNavigationDelegate,
  WKUIDelegate, NSSearchFieldDelegate
{
  let window: NSWindow
  var onAutoLoginSettings: ((String) -> Void)?
  var onSampleLimitSettings: (() -> Void)?

  private enum ToolbarIdentifier {
    static let toolbar = NSToolbar.Identifier("SMSMonitorPlatformToolbar")
    static let back = NSToolbarItem.Identifier("SMSMonitorPlatformBack")
    static let forward = NSToolbarItem.Identifier("SMSMonitorPlatformForward")
    static let reload = NSToolbarItem.Identifier("SMSMonitorPlatformReload")
    static let address = NSToolbarItem.Identifier("SMSMonitorPlatformAddress")
    static let find = NSToolbarItem.Identifier("SMSMonitorPlatformFind")
    static let autoLogin = NSToolbarItem.Identifier("SMSMonitorPlatformAutoLogin")
    static let sampleLimit = NSToolbarItem.Identifier("SMSMonitorPlatformSampleLimit")
    static let addPage = NSToolbarItem.Identifier("SMSMonitorPlatformAddPage")
    static let closePage = NSToolbarItem.Identifier("SMSMonitorPlatformClosePage")
    static let renamePage = NSToolbarItem.Identifier("SMSMonitorPlatformRenamePage")
  }

  private static let savedPagesKey = "SMSMonitorPlatformPages.v1"

  private let defaultInitialURL: URL
  private let monitoredPageCount: Int
  private var sampleLimit: Int
  private let tabController = WorkspaceTabViewController()
  private var pages: [PlatformPageViewController] = []
  private var addressField: NSTextField?
  private var findField: NSSearchField?
  private var findNavigationControl: NSSegmentedControl?
  private var backItem: NSToolbarItem?
  private var forwardItem: NSToolbarItem?
  private var reloadItem: NSToolbarItem?
  private var sampleLimitItem: NSToolbarItem?
  private var autoLoginItem: NSToolbarItem?
  private var closePageItem: NSToolbarItem?
  private var renamePageItem: NSToolbarItem?

  init(sampleLimit: Int, monitoredPages: [MonitoredPlatformPage]) {
    precondition(!monitoredPages.isEmpty)
    self.defaultInitialURL = monitoredPages[0].configuration.targetURL
    self.monitoredPageCount = monitoredPages.count
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
    restoreAdditionalPages()
    updateToolbar()
  }

  func show(moduleID: String? = nil) {
    if let moduleID,
      let index = pages.firstIndex(where: { $0.monitorID == moduleID })
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
    guard let page = pages.first(where: { $0.monitorID == moduleID }) else { return }
    guard let item = tabController.tabViewItems.first(where: { $0.viewController === page }) else {
      return
    }
    item.toolTip = "\(page.pageName) · \(Self.stateDescription(state))"
    item.image = NSImage(
      systemSymbolName: Self.stateSymbol(state),
      accessibilityDescription: Self.stateDescription(state)
    )
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
    findInSelectedPage(backwards: false)
  }

  func stopAll() {
    for page in pages {
      page.webView.stopLoading()
    }
  }

  private func configureWindow() {
    tabController.tabStyle = .segmentedControlOnTop
    tabController.canPropagateSelectedChildViewControllerTitle = false
    tabController.onSelectionChange = { [weak self] in
      self?.updateToolbar()
      self?.findInSelectedPage(backwards: false)
    }

    window.contentViewController = tabController
    window.title = "短信后台工作台"
    updateWindowSubtitle()
    window.minSize = NSSize(width: 940, height: 620)
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

  private func updateWindowSubtitle() {
    window.subtitle =
      "\(monitoredPageCount) 个监控后台 · 样本 \(sampleLimit) 条 · 不同标签使用独立登录会话"
  }

  private func restoreAdditionalPages() {
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
    tabItem.toolTip =
      page.isMonitored
      ? "\(page.pageName) · 等待连接"
      : "独立登录页面：\(page.pageName)"
    tabController.addTabViewItem(tabItem)

    if select {
      tabController.selectedTabViewItemIndex = pages.count - 1
    }
  }

  private func createAdditionalPage(
    id: UUID = UUID(),
    name: String,
    startURL: URL,
    select: Bool,
    persist: Bool = true
  ) {
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
    webView.navigationDelegate = self
    webView.uiDelegate = self

    let page = PlatformPageViewController(
      id: id,
      name: name,
      startURL: startURL,
      webView: webView
    )
    addPage(page, select: select)
    webView.load(URLRequest(url: startURL))

    if persist {
      saveAdditionalPages()
    }
  }

  private var selectedPage: PlatformPageViewController? {
    let index = tabController.selectedTabViewItemIndex
    guard pages.indices.contains(index) else { return nil }
    return pages[index]
  }

  private func updateToolbar() {
    guard let page = selectedPage else { return }
    addressField?.stringValue = page.webView.url?.absoluteString ?? page.startURL.absoluteString
    backItem?.isEnabled = page.webView.canGoBack
    forwardItem?.isEnabled = page.webView.canGoForward
    closePageItem?.isEnabled = !page.isMonitored
    renamePageItem?.isEnabled = !page.isMonitored
    autoLoginItem?.isEnabled = page.isMonitored

    let isLoading = page.webView.isLoading
    reloadItem?.image = NSImage(
      systemSymbolName: isLoading ? "xmark" : "arrow.clockwise",
      accessibilityDescription: isLoading ? "停止加载" : "刷新"
    )
    reloadItem?.toolTip = isLoading ? "停止加载" : "刷新当前页面"
  }

  private func saveAdditionalPages() {
    let savedPages = pages.filter { !$0.isMonitored }.map {
      SavedPlatformPage(id: $0.id, name: $0.pageName, startURL: $0.startURL)
    }
    guard let data = try? JSONEncoder().encode(savedPages) else { return }
    UserDefaults.standard.set(data, forKey: Self.savedPagesKey)
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

  @objc private func configureAutoLogin() {
    guard let monitorID = selectedPage?.monitorID else { return }
    onAutoLoginSettings?(monitorID)
  }

  @objc private func configureSampleLimit() {
    onSampleLimitSettings?()
  }

  @objc private func navigateFindResult(_ sender: NSSegmentedControl) {
    findInSelectedPage(backwards: sender.selectedSegment == 0)
  }

  private func findInSelectedPage(backwards: Bool) {
    guard let webView = selectedPage?.webView, let findField else { return }
    let query = findField.stringValue
    findNavigationControl?.isEnabled = !query.isEmpty
    guard !query.isEmpty else {
      findField.textColor = .labelColor
      findField.toolTip = "查找当前后台网页内容"
      webView.find("", configuration: WKFindConfiguration()) { _ in }
      return
    }

    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    configuration.caseSensitive = false
    configuration.wraps = true
    webView.find(query, configuration: configuration) { [weak self, weak webView] result in
      guard let self, let webView, webView === self.selectedPage?.webView else { return }
      guard query == self.findField?.stringValue else { return }
      self.findField?.textColor = result.matchFound ? .labelColor : .systemRed
      self.findField?.toolTip = result.matchFound ? "已找到匹配项" : "当前网页中未找到"
      self.findNavigationControl?.isEnabled = result.matchFound
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField, field === findField else { return }
    findInSelectedPage(backwards: false)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === findField else { return false }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
      findInSelectedPage(backwards: backwards)
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      findField?.stringValue = ""
      findInSelectedPage(backwards: false)
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

    if !page.isMonitored {
      page.startURL = url
      saveAdditionalPages()
    }
    page.webView.load(URLRequest(url: url))
  }

  @objc private func addNewPage() {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "新增独立后台页面"
    alert.informativeText = "新页面使用独立登录会话，但不会自动加入短信成功率监控。"
    alert.addButton(withTitle: "创建页面")
    alert.addButton(withTitle: "取消")

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 82))
    let nameLabel = NSTextField(labelWithString: "页面名称")
    nameLabel.frame = NSRect(x: 0, y: 53, width: 76, height: 20)
    nameLabel.alignment = .right

    let customPageCount = pages.count(where: { !$0.isMonitored })
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
    guard let page = selectedPage, !page.isMonitored else { return }
    guard let item = tabController.tabViewItems.first(where: { $0.viewController === page }) else {
      return
    }

    let pageID = page.id
    page.webView.stopLoading()
    tabController.removeTabViewItem(item)
    pages.removeAll { $0 === page }
    saveAdditionalPages()
    updateToolbar()

    if #available(macOS 14.0, *) {
      DispatchQueue.main.async {
        WKWebsiteDataStore.remove(forIdentifier: pageID) { error in
          if let error {
            NSLog("Unable to remove platform page data store: %@", error.localizedDescription)
          }
        }
      }
    }
  }

  @objc private func renameCurrentPage() {
    guard let page = selectedPage, !page.isMonitored else { return }
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
      self.saveAdditionalPages()
      self.updateToolbar()
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

      let stack = NSStackView(views: [field, navigation])
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = 4
      stack.frame = NSRect(x: 0, y: 0, width: 224, height: 28)

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
        toolTip: "新增独立登录页面",
        action: #selector(addNewPage)
      )

    case ToolbarIdentifier.closePage:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "关闭页面",
        symbol: "xmark.circle",
        toolTip: "关闭当前自定义页面",
        action: #selector(closeCurrentPage)
      )
      closePageItem = item
      return item

    case ToolbarIdentifier.renamePage:
      let item = toolbarButton(
        identifier: itemIdentifier,
        label: "重命名",
        symbol: "pencil",
        toolTip: "修改当前自定义页面名称",
        action: #selector(renameCurrentPage)
      )
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

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard pages.first(where: { $0.webView === webView })?.isMonitored == false else { return }
    webView.reload()
  }
}
