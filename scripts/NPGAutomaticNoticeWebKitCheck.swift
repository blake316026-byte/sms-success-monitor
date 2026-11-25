import AppKit
import WebKit

@main struct NPGAutomaticNoticeWebKitCheck {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 550), configuration: configuration)
    let source = URL(string: "https://npg-notice.test.invalid/report")!
    let fixture = #"""
      <!doctype html><html><body><main></main><script>
      window.closedNotices = [];
      window.businessActions = 0;
      window.showNotice = (id, title, options = {}) => {
        const model = {id, title, type: options.type || 'IMPORTANT', content: 'Fixture content ' + id};
        const wrap = document.createElement('div');
        wrap.className = 'ant-modal-wrap';
        wrap.id = 'notice-' + id;
        wrap.innerHTML = '<div role="dialog"><div class="ant-modal-content">' +
          '<button class="ant-modal-close" type="button">×</button>' +
          '<div class="ant-modal-header"><div class="ant-modal-title"></div></div>' +
          '<div class="ant-modal-body"><pre></pre></div>' +
          '<div class="ant-modal-footer"><button type="button">处理</button></div></div></div>';
        const panel = wrap.querySelector('.ant-modal-content');
        panel['__reactFiber$fixture'] = {return: {memoizedProps: options.manual ? {notice: model} : {m: model}}};
        panel.querySelector('.ant-modal-title').textContent = title + '  (2026-11-25 08:20:48)';
        panel.querySelector('pre').textContent = options.mismatch ? 'Different content' : model.content;
        if (options.edit) panel.querySelector('.ant-modal-body').insertAdjacentHTML('beforeend',
          '<div class="ant-select"><input type="search" role="combobox"><span class="ant-select-selection-placeholder">处理结果</span></div>' +
          '<textarea placeholder="备注"></textarea>');
        if (options.edit === 'draft') panel.querySelector('textarea').value = '未提交';
        if (options.edit === 'selected') panel.querySelector('.ant-select').insertAdjacentHTML('beforeend',
          '<span class="ant-select-selection-item">已选</span>');
        const close = panel.querySelector('.ant-modal-close');
        if (options.disabled) close.disabled = true;
        close.onclick = () => { window.closedNotices.push(id); wrap.remove(); };
        panel.querySelector('.ant-modal-footer button').onclick = () => window.businessActions++;
        document.body.append(wrap);
      };
      </script></body></html>
      """#
    func execute(_ script: String) async throws {
      _ = try await view.evaluateJavaScript(script + ";void 0")
    }
    func check(_ expression: String, _ message: String) async throws {
      for _ in 0..<70 {
        if try await view.evaluateJavaScript(expression) as? Bool == true { return }
        try await Task.sleep(nanoseconds: 60_000_000)
      }
      preconditionFailure(message)
    }
    func load() async throws {
      view.loadHTMLString(fixture, baseURL: source)
      for _ in 0..<70 {
        if !view.isLoading, (try? await view.evaluateJavaScript("typeof showNotice==='function'")) as? Bool == true { return }
        try await Task.sleep(nanoseconds: 60_000_000)
      }
      preconditionFailure("fixture did not load")
    }
    try await load()
    try await execute("localStorage.setItem('lt-user',JSON.stringify({username:'fixture',token:'fixture-token'}))")
    try await execute("showNotice('one','域名过期告警',{edit:'blank'})")
    NPGAutomaticNotice.start(in: view, source: URL(string: "https://other.test.invalid/")!)
    try await Task.sleep(nanoseconds: 250_000_000)
    try await check("closedNotices.length===0", "a different backend origin must not touch the notice")
    NPGAutomaticNotice.start(in: view, source: source)
    try await check("typeof window.__smsNPGAutomaticNotice === 'object'", "same-origin observer should be installed")
    try await check("closedNotices.join() === 'one'", "the visible automatic notice should close via its own button")
    try await execute("showNotice('two','系统维护通知',{type:'ADVICE'});showNotice('three','运营消息',{type:'MESSAGE'})")
    try await check("closedNotices.join() === 'one,two,three'", "late automatic notices close regardless of their titles")
    try await execute("showNotice('manual','系统维护通知',{manual:true});showNotice('four','告警')")
    try await Task.sleep(nanoseconds: 250_000_000)
    try await check("closedNotices.length===3 && !!document.getElementById('notice-manual')",
      "notice center and stacked automatic notice remain while the user is viewing the center")
    try await execute("document.getElementById('notice-manual').remove()")
    try await check("closedNotices.includes('four')", "the pending notice closes after the center is closed")
    for options in ["{edit:'draft'}", "{edit:'selected'}", "{disabled:true}", "{mismatch:true}", "{manual:true}"] {
      try await execute("showNotice('protected','通知',\(options))")
      try await Task.sleep(nanoseconds: 250_000_000)
      try await check("!closedNotices.includes('protected') && !!document.getElementById('notice-protected')",
        "a draft, a selected action, an unusable close or a manually opened dialog must remain")
      try await execute("document.getElementById('notice-protected').remove()")
    }
    NPGAutomaticNotice.stop(in: view)
    try await execute("showNotice('reselected','重新选择平台')")
    try await Task.sleep(nanoseconds: 250_000_000)
    try await check("!closedNotices.includes('reselected')", "inactive pages do not close dialogs")
    NPGAutomaticNotice.start(in: view, source: source)
    try await check("closedNotices.includes('reselected')", "activating an existing page checks its current popup")
    try await load()
    try await execute("showNotice('new-document','重新加载后的通知')")
    NPGAutomaticNotice.start(in: view, source: source)
    try await check("closedNotices.includes('new-document') && businessActions===0", "new documents are reattached without handling a notice")
    try await execute("localStorage.setItem('__smsMonitorSignedOut','1');showNotice('signed-out','登录已过期')")
    try await Task.sleep(nanoseconds: 250_000_000)
    try await check("!closedNotices.includes('signed-out')", "signed-out or non-NPG pages must not be modified")
    print("PASS: NPG notice provenance, current origin, delayed/stacked notices, manual center, draft and activation/reload in native WebKit")
  }
}
