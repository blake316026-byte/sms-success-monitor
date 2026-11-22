// Appended to the workspace source so the test exercises the real move/return paths.
private final class DetachedTabsFixture: NSObject, WKURLSchemeHandler {
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let html = """
    <html><body style="margin:24px;font:16px system-ui;background:white;color:#222;height:2400px">
    <h2>Configuration fixture</h2><input id="draft" value="Unsaved text"><textarea id="notes">Unsaved notes</textarea>
    <div style="position:absolute;top:500px;border-top:2px solid #198052;width:85%;padding:20px">Retained page content at scroll position 420</div>
    <script>window.fixtureHeap={kept:123}; sessionStorage.setItem('fixtureSession','kept');</script>
    </body></html>
    """
    let data=Data(html.utf8)
    task.didReceive(URLResponse(url:task.request.url!,mimeType:"text/html",expectedContentLength:data.count,textEncodingName:"utf-8"))
    task.didReceive(data); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private final class FixtureTabPan: NSPanGestureRecognizer {
  var phase:NSGestureRecognizer.State = .possible
  var point=NSPoint.zero
  override var state:NSGestureRecognizer.State { get { phase } set { phase=newValue } }
  override func location(in view:NSView?) -> NSPoint { point }
}

extension WrappingTabBarView {
  fileprivate func simulateDragOut() {
    layoutSubtreeIfNeeded()
    let pan=FixtureTabPan()
    pan.point=NSPoint(x:buttons[0].frame.midX,y:buttons[0].frame.midY)
    pan.phase = .began; handleTabDrag(pan)
    if buttons.count > 1 {
      pan.point=NSPoint(x:buttons[1].frame.midX,y:buttons[1].frame.midY)
      pan.phase = .changed; handleTabDrag(pan)
    }
    pan.point=NSPoint(x:bounds.maxX+100,y:bounds.maxY+100)
    pan.phase = .ended; handleTabDrag(pan)
  }
}

extension PlatformWorkspaceController {
  @MainActor fileprivate static func checkDetachedTabs() async throws {
    func require(_ ok:Bool,_ message:String) {
      guard ok else { print("FAIL: " + message); exit(1) }
      print("PASS: " + message)
    }
    func wait(_ check:()->Bool) async throws {
      for _ in 0..<200 {
        if check() { return }
        try await Task.sleep(nanoseconds:50_000_000)
      }
      require(false,"fixture timed out")
    }
    let suite="SMSMonitor.DetachedTests." + UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let fixture=DetachedTabsFixture()
    let descriptors:[MonitoredPlatformPage]=(0..<3).map { index in
      let config=WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.setURLSchemeHandler(fixture,forURLScheme:"sms-tab-fixture")
      return MonitoredPlatformPage(configuration:MonitorConfiguration(id:"tab-fixture-\(index)",
        displayName:index == 0 ? "cg09" : index == 1 ? "cg14" : "Mexico",targetURL:URL(string:"sms-tab-fixture://platform-\(index)/index")!,
        sampleLimit:300,scanInterval:60,alertThreshold:0.5),
        webView:WKWebView(frame:NSRect(x:0,y:0,width:900,height:650),configuration:config))
    }
    let workspace=PlatformWorkspaceController(sampleLimit:300,monitoredPages:descriptors,
      credentialStore:LocalCredentialStore(),isLayoutTest:true)
    workspace.window.orderFront(nil)
    defer { workspace.window.orderOut(nil) }
    let page=workspace.pages[0], other=workspace.pages[1], original=page.webView
    original.load(URLRequest(url:page.startURL))
    try await wait { original.url == page.startURL && !original.isLoading }
    _ = try await original.evaluateJavaScript("document.getElementById('draft').value='draft cg09'; history.pushState({fixture:1},'', '#draft'); window.scrollTo(0,420); true;")
    let stateScript="JSON.stringify({value:document.getElementById('draft').value,notes:document.getElementById('notes').value,session:sessionStorage.getItem('fixtureSession'),heap:fixtureHeap.kept,url:location.href,history:history.length,scroll:scrollY})"
    let before=try await original.evaluateJavaScript(stateScript) as! String
    let dataStore=original.configuration.websiteDataStore
    PlatformPageOperationActivity.begin(original)
    require(!workspace.detachPage(page),"busy payment/query page cannot be moved")
    PlatformPageOperationActivity.end(original)
    workspace.workspaceContainer.tabBar.simulateDragOut()
    try await wait { workspace.detachedWindows[page.credentialID] != nil }
    require(workspace.detachedWindows[page.credentialID] != nil,"drag-out after reorder preview moves the original platform")
    let detached=workspace.detachedWindows[page.credentialID]!
    detached.window?.orderFront(nil)
    try await wait { workspace.movingPlatformIDs.isEmpty }
    detached.window?.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds:300_000_000)
    require(page.webView === original && original.superview === detached.contentHost
      && original.configuration.websiteDataStore === dataStore,"same WebView and login store reparented; no second session")
    require(workspace.selectedPage === other && workspace.activeCredentialIDs == Set([page.credentialID,other.credentialID]),
      "main and detached pages both remain protected from memory compaction")
    let afterDetach=try await original.evaluateJavaScript(stateScript) as! String
    if afterDetach != before { print("Before: " + before + "\nDetached: " + afterDetach) }
    require(afterDetach == before,
      "form, JS heap, session storage, history, URL and scroll retained on detach")
    workspace.tabController.selectedTabViewItemIndex=2
    require(workspace.activeCredentialIDs.contains(page.credentialID),"country filtering does not deactivate detached platform")
    require(!workspace.receiveDetachedDrop(source:DetachedPlatformTitleButton(),value:detached.titleButton.dragID),
      "unowned drag source rejected")
    require(!workspace.receiveDetachedDrop(source:detached.titleButton,value:"wrong"),"invalid drag payload rejected")
    for width in [620.0,1000.0] {
      detached.window?.setContentSize(NSSize(width:width,height:650))
      let root=detached.window!.contentView!
      root.layoutSubtreeIfNeeded()
      require(detached.contentHost.frame.width == width && detached.contentHost.frame.height > 500,
        "detached page framed at width \(Int(width))")
      let buttons=root.subviews.first!.subviews.compactMap { $0 as? NSButton }
      require(buttons.count == 5 && buttons.allSatisfy { $0.frame.width >= 30 && $0.frame.maxX <= width },
        "toolbar remains within window at width \(Int(width))")
      if let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds) {
        root.cacheDisplay(in:root.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sms-detached-\(Int(width)).png"))
      }
    }
    PlatformPageOperationActivity.begin(original)
    detached.window?.performClose(nil)
    require(workspace.detachedWindows[page.credentialID] != nil,"close during payment/query does not move the page")
    PlatformPageOperationActivity.end(original)
    let beforeReturn=try await original.evaluateJavaScript(stateScript) as! String
    if beforeReturn != before { print("After resize: " + beforeReturn) }
    require(workspace.receiveDetachedDrop(source:detached.titleButton,value:detached.titleButton.dragID),"owned header drag returns to main tabs")
    try await wait { workspace.movingPlatformIDs.isEmpty }
    require(page.webView === original && original.superview === page.view
      && workspace.selectedPage === page,"return selects original platform and country")
    let returned=try await original.evaluateJavaScript(stateScript) as! String
    if returned != before { print("Before: " + before + "\nReturned: " + returned) }
    require(returned == before,"all page state retained after return")
    require(workspace.detachPage(page),"platform can detach again")
    try await wait { workspace.movingPlatformIDs.isEmpty }
    workspace.detachedWindows[page.credentialID]?.window?.performClose(nil)
    try await wait { workspace.movingPlatformIDs.isEmpty }
    require(workspace.detachedWindows.isEmpty && workspace.pages.count == 3 && page.webView === original,
      "closing detached window returns tab without deleting platform or session")
    require(workspace.detachPage(page) && workspace.detachPage(other),"multiple independent platforms supported")
    try await wait { workspace.movingPlatformIDs.isEmpty }
    require(workspace.activeCredentialIDs.isSuperset(of:[page.credentialID,other.credentialID]),"both detached pages stay active")
    require(workspace.returnDetachedPage(page.credentialID) && workspace.returnDetachedPage(other.credentialID),
      "multiple windows return cleanly")
    try await wait { workspace.movingPlatformIDs.isEmpty }
    require((try await original.evaluateJavaScript(stateScript) as? String) == before,"repeated moves preserve unsaved state")
  }
}

private final class DetachedTabsApplicationDelegate:NSObject,NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
  func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { .terminateCancel }
}

@main struct DetachedTabsWebKitCheck {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let delegate=DetachedTabsApplicationDelegate()
    NSApplication.shared.delegate=delegate
    Task { @MainActor in
      do {
        try await PlatformWorkspaceController.checkDetachedTabs()
        print("PASS: detachable tabs complete")
        exit(0)
      } catch { print("FAIL: " + error.localizedDescription); exit(1) }
    }
    NSApplication.shared.run()
    withExtendedLifetime(delegate) {}
  }
}
