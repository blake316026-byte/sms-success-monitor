// Appended to the production controller. All requests and credentials are isolated fixtures.
private final class TianchengMemoryFixture: NSObject, WKURLSchemeHandler {
  static let mocks = #"""
    window.smsTianchengLogin={snapshot:()=>({kind:'authenticated'})};
    window.smsTianchengSession={snapshot:()=>({kind:'none'})};
    window.fixtureExpired=false;
    window.fetch=async(path,options)=>{
      if(options.method !== 'GET') throw Error('Unexpected business write');
      if(String(path).includes('operator-ga-status'))
        return {status:200,ok:true,json:async()=>({success:true,value:{expired:window.fixtureExpired,
          fixedVerifyIntervalMinutes:240,idleTimeoutMinutes:60,fixedVerifyExpireAt:100,idleExpireAt:200}})};
      if(String(path).includes('ods-report-profitloss-summary-get'))
        return {status:200,ok:true,json:async()=>({success:true,value:{deposit:123,withdraw:45}})};
      throw Error('Unexpected request');
    };
    """#
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let html = "<html><body>Fixture<script>\(Self.mocks)</script></body></html>"
    let data = Data(html.utf8)
    task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
      expectedContentLength: data.count, textEncodingName: "utf-8"))
    task.didReceive(data); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

extension ModuleMonitorController {
  @MainActor fileprivate static func checkTianchengMemory() async throws {
    func require(_ ok: Bool, _ message: String) {
      guard ok else { print("FAIL: \(message)"); exit(1) }
      print("PASS: \(message)")
    }
    func wait(_ predicate: () -> Bool) async throws {
      for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      require(false, "fixture timed out")
    }
    let store=LocalCredentialStore(), id="tc-memory-fixture"
    let profile=LocalLoginProfile(username:"fixture",password:"fixture",totpSecret:"",token:"",autoLoginEnabled:true)
    require(store.save(profile,for:id),"isolated credentials saved")
    let config=WKWebViewConfiguration(), fixture=TianchengMemoryFixture()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(fixture,forURLScheme:"sms-memory-fixture")
    let page=WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:config)
    let url=URL(string:"sms-memory-fixture://platform/index")!
    let monitor=ModuleMonitorController(configuration:MonitorConfiguration(id:id,displayName:"Fixture",
      targetURL:url,sampleLimit:20,scanInterval:60,alertThreshold:0.5),sampleLimit:20,
      credentialStore:store,automationRuntime:LocalAutomationRuntime(),loginAutomation:LoginPageAutomation(),webView:page)
    monitor.platformIdentified=true
    page.load(URLRequest(url:url))
    try await wait { page.url == url && !page.isLoading }
    _ = try await page.evaluateJavaScript(#"""
      for(const [k,v] of Object.entries({user:'{"operatorName":"fixture"}',token:'fixture-token-long',
        tabIsLogin:'1',merchantParam:'merchant',merchants:'[{"merchantCode":"merchant","merchantCurrency":"PHP"}]',
        permission:'[31711]',platform:'B2C',environment:'TCG1',fixture:'retained'})) sessionStorage.setItem(k,v);
      localStorage.setItem('TOKEN','fixture-token-long');
      localStorage.setItem('OPERATOR_NAME','fixture');
      localStorage.setItem('operatorCustomization','{"customTimezone":"Etc/GMT-8"}');
      """#)
    monitor.isStarted=true
    monitor.monitoringEnabled=true
    monitor.financialMonitoringEnabled=true
    monitor.tianchengAuthenticated=true
    monitor.inactiveSince=Date().addingTimeInterval(-40)
    monitor.onWebViewReplacement={_,_ in}
    monitor.tianchengLogin=TianchengLoginController(webView:page,origin:url,credentialID:id,
      store:store,runtime:LocalAutomationRuntime(),onState:{_ in})
    monitor.tianchengLogin?.start()
    try await wait { monitor.tianchengLogin?.canSuspendForMemory == true }
    PlatformPageOperationActivity.begin(page)
    monitor.compactInactivePageIfNeeded(now:Date())
    require(!monitor.isMemoryCompactionInProgress,"payment lease prevents compaction")
    PlatformPageOperationActivity.end(page)
    _ = try await page.evaluateJavaScript("window.__smsMemoryActivity.touched=true")
    monitor.compactInactivePageIfNeeded(now:Date())
    try await wait { !monitor.isMemoryCompactionInProgress }
    require(monitor.webView === page && !monitor.isMemoryCompacted,"edited page is preserved")
    try await wait { monitor.tianchengLogin?.canSuspendForMemory == true }
    _ = try await page.evaluateJavaScript("window.__smsMemoryActivity.touched=false")
    monitor.compactInactivePageIfNeeded(now:Date())
    try await wait { monitor.isMemoryCompacted && !monitor.webView.isLoading }
    var shell=monitor.webView
    require(shell !== page && monitor.compactedTianchengSession && !monitor.isPageActive,
      "authenticated hidden Tiancheng page becomes a lightweight view without selecting the tab")
    require((try await shell.evaluateJavaScript("sessionStorage.getItem('fixture')")) as? String == "retained",
      "session storage survives the WebView replacement")
    _ = try await shell.evaluateJavaScript(TianchengMemoryFixture.mocks + "\ntrue;")
    monitor.refreshTianchengFinancialMetrics()
    try await wait { !monitor.isRefreshingFinancial }
    require(monitor.latestDailyFinancialMetrics?.rechargeAmount == 123
      && monitor.latestDailyFinancialMetrics?.withdrawAmount == 45,"finance queries continue in the lightweight view")
    monitor.maintainAuthentication()
    try await wait { monitor.compactedSessionCheckID == nil }
    require(monitor.isMemoryCompacted,"valid Google verification does not reload the heavy frontend")
    PlatformPageOperationActivity.begin(shell)
    monitor.isPageActive=true
    monitor.restoreCompactedPageIfNeeded()
    require(monitor.isMemoryCompacted,"opening a detached page waits for the active operation")
    PlatformPageOperationActivity.end(shell)
    monitor.maintainAuthentication()
    try await wait { !monitor.isMemoryCompacted && !monitor.webView.isLoading }
    require(monitor.webView.url == url,"active page restores after its operation ends")
    monitor.isPageActive=false
    monitor.inactiveSince=Date().addingTimeInterval(-40)
    try await wait { monitor.tianchengLogin?.canSuspendForMemory == true }
    monitor.compactInactivePageIfNeeded(now:Date())
    try await wait { monitor.isMemoryCompacted && !monitor.webView.isLoading }
    shell=monitor.webView
    _ = try await shell.evaluateJavaScript(TianchengMemoryFixture.mocks + "\ntrue;")
    _ = try await shell.evaluateJavaScript("window.fixtureExpired=true")
    monitor.lastCompactedSessionCheckAt=nil
    PlatformPageOperationActivity.begin(shell)
    monitor.maintainAuthentication()
    monitor.restoreCompactedPageIfNeeded()
    require(monitor.isMemoryCompacted,"payment lease also prevents periodic and direct restoration")
    PlatformPageOperationActivity.end(shell)
    monitor.maintainAuthentication()
    try await wait { !monitor.isMemoryCompacted && !monitor.webView.isLoading }
    require(monitor.webView.url == url && !monitor.isPageActive,
      "expired Google verification wakes the full page without a tab click or business-action replay")
    require(store.profile(for:id) == profile,"account configuration remains unchanged")
    monitor.stop()
  }
}
@main struct TianchengMemoryWebKitCheck {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try await ModuleMonitorController.checkTianchengMemory()
  }
}
