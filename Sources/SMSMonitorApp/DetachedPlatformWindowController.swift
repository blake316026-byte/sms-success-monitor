import AppKit
import WebKit

final class DetachedPlatformTitleButton: NSButton, NSDraggingSource {
  static let pasteboardType = NSPasteboard.PasteboardType("com.local.sms-monitor.detached-platform")
  let dragID = UUID().uuidString

  override func mouseDown(with event:NSEvent) {
    guard let window else { return }
    while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
      if next.type == .leftMouseUp { return }
      if hypot(next.locationInWindow.x-event.locationInWindow.x,next.locationInWindow.y-event.locationInWindow.y) >= 5 {
        mouseDragged(with:next)
        return
      }
    }
  }
  override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }

  override func mouseDragged(with event: NSEvent) {
    let data = NSPasteboardItem()
    data.setString(dragID, forType: Self.pasteboardType)
    let item = NSDraggingItem(pasteboardWriter: data)
    let image = NSImage(size: bounds.size)
    image.lockFocus()
    cell?.draw(withFrame: NSRect(origin: .zero, size: bounds.size), in: self)
    image.unlockFocus()
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }
}

final class DetachedPlatformWindowController: NSWindowController, NSWindowDelegate {
  let contentHost = NSView()
  let titleButton = DetachedPlatformTitleButton()
  var webView: (() -> WKWebView?)?
  var onReturn: (() -> Bool)?
  private let back = NSButton(), forward = NSButton(), reload = NSButton(), merge = NSButton()

  init(name: String, country: String) {
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1000,height:760),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    super.init(window:window)
    window.title = name + " · " + Self.countryName(country)
    window.minSize = NSSize(width:620,height:500)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    titleButton.title = window.title
    titleButton.bezelStyle = .texturedRounded
    titleButton.image = NSImage(systemSymbolName:"macwindow",accessibilityDescription:"平台窗口")
    titleButton.imagePosition = .imageLeading
    titleButton.lineBreakMode = .byTruncatingTail
    titleButton.toolTip = "拖回主窗口标签栏"
    titleButton.setContentCompressionResistancePriority(.defaultLow, for:.horizontal)
    let toolbar = NSStackView(views:[titleButton,back,forward,reload,merge])
    toolbar.orientation = .horizontal; toolbar.spacing = 6
    toolbar.edgeInsets = NSEdgeInsets(top:6,left:8,bottom:6,right:8)
    for (button,symbol,label,action) in [
      (back,"chevron.left","返回",#selector(goBack)),
      (forward,"chevron.right","前进",#selector(goForward)),
      (reload,"arrow.clockwise","刷新",#selector(reloadPage)),
      (merge,"rectangle.on.rectangle","放回主窗口",#selector(returnPage))
    ] {
      button.bezelStyle = .texturedRounded
      button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label)
      button.toolTip = label; button.setAccessibilityLabel(label)
      button.target = self; button.action = action
      button.widthAnchor.constraint(equalToConstant:32).isActive = true
    }
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    contentHost.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(toolbar); root.addSubview(contentHost)
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo:root.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo:root.trailingAnchor),
      toolbar.topAnchor.constraint(equalTo:root.topAnchor),
      toolbar.heightAnchor.constraint(equalToConstant:44),
      contentHost.topAnchor.constraint(equalTo:toolbar.bottomAnchor),
      contentHost.leadingAnchor.constraint(equalTo:root.leadingAnchor),
      contentHost.trailingAnchor.constraint(equalTo:root.trailingAnchor),
      contentHost.bottomAnchor.constraint(equalTo:root.bottomAnchor),
      titleButton.widthAnchor.constraint(greaterThanOrEqualToConstant:120)
    ])
    window.contentView = root
    root.layoutSubtreeIfNeeded()
  }

  required init?(coder:NSCoder) { nil }
  func update(name:String,country:String) {
    window?.title = name + " · " + Self.countryName(country)
    titleButton.title = window?.title ?? name
    let view=webView?()
    window?.subtitle = view?.url?.host ?? ""
    back.isEnabled = view?.canGoBack == true
    forward.isEnabled = view?.canGoForward == true
    reload.image = NSImage(systemSymbolName:view?.isLoading == true ? "xmark" : "arrow.clockwise",accessibilityDescription:"刷新或停止")
  }
  private static func countryName(_ code:String) -> String {
    code
  }
  @objc private func goBack() {
    guard let view=webView?(), !PlatformPageOperationActivity.isInUse(view) else { NSSound.beep(); return }
    view.goBack()
  }
  @objc private func goForward() {
    guard let view=webView?(), !PlatformPageOperationActivity.isInUse(view) else { NSSound.beep(); return }
    view.goForward()
  }
  @objc private func reloadPage() {
    guard let view=webView?(), !PlatformPageOperationActivity.isInUse(view) else { NSSound.beep(); return }
    if view.isLoading { view.stopLoading() } else { view.reload() }
  }
  @objc private func returnPage() { _ = onReturn?() }
  func windowShouldClose(_ sender:NSWindow) -> Bool {
    _ = onReturn?()
    return false
  }
}
