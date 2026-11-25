import Foundation
import OSLog
import WebKit

@MainActor
final class NPGAutomaticNotice: NSObject, WKScriptMessageHandler {
  private static let handler = NPGAutomaticNotice()
  private static let configured = NSHashTable<WKUserContentController>.weakObjects()
  private static let logger = Logger(subsystem: "com.local.sms-success-monitor", category: "NPGNotices")

  static func start(in webView: WKWebView, source: URL) {
    let defaultPort = source.scheme == "https" ? 443 : 80
    guard !webView.isLoading, let page = webView.url, page.scheme == source.scheme,
      page.host == source.host, (page.port ?? defaultPort) == (source.port ?? defaultPort),
      var origin = URLComponents(url: source, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(origin.scheme), origin.host != nil,
      origin.user == nil, origin.password == nil else { return }
    origin.path = ""
    origin.query = nil
    origin.fragment = nil
    guard let expectedOrigin = origin.url?.absoluteString else { return }
    let content = webView.configuration.userContentController
    if !configured.contains(content) {
      configured.add(content)
      content.add(handler, name: "smsNPGAutomaticNotice")
    }
    webView.callAsyncJavaScript(body, arguments: ["expectedOrigin": expectedOrigin], in: nil, in: .page) { _ in }
  }

  static func stop(in webView: WKWebView) {
    webView.evaluateJavaScript("window.__smsNPGAutomaticNotice?.stop();void 0", completionHandler: nil)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, message.body as? String == "closed" else { return }
    Self.logger.notice("Closed an automatic NPG notification")
  }

  static let body = #"""
    if (location.origin !== new URL(expectedOrigin).origin) return;
    if (window.__smsNPGAutomaticNotice) {
      window.__smsNPGAutomaticNotice.start();
      return;
    }

    const dialogs = '.ant-modal-content,.ant-drawer-content,[role="dialog"],.el-dialog__wrapper,.ga-verify-modal';
    const modalTree = '.ant-modal-root,.ant-modal-wrap,' + dialogs;
    const fields = 'input:not([type="hidden"]),textarea,select,[contenteditable]:not([contenteditable="false"]),[role="combobox"],[role="switch"],[role="checkbox"],[role="radio"],[role="slider"],[role="textbox"],[role="spinbutton"]';
    const visible = node => node.getClientRects().length > 0 && getComputedStyle(node).visibility === 'visible'
      && !node.closest('[aria-hidden="true"],[inert]');
    const tidy = value => (value ?? '').replace(/\s+/g, ' ').trim();
    const interacted = new WeakSet();
    const attempted = new WeakMap();

    const npgSession = () => {
      if (['/login', '/ga-auth', '/unlock-ip'].includes(location.pathname)) return false;
      try {
        if (window.__smsMonitorSignedOut || localStorage.getItem('__smsMonitorSignedOut') === '1') return false;
        return [sessionStorage, localStorage].some(store => {
          for (let i = 0; i < store.length; i++) {
            const key = store.key(i);
            if (key !== 'lt-user' && !key?.endsWith('-lt-user')) continue;
            try {
              const user = JSON.parse(store.getItem(key));
              if (typeof user?.token === 'string' && user.token && (user.username || user.account || user.loginName || user.id)) return true;
            } catch (_) {}
          }
          return false;
        });
      } catch (_) { return false; }
    };

    const autoNotice = panel => {
      const title = tidy(panel.querySelector('.ant-modal-header .ant-modal-title')?.textContent);
      const message = panel.querySelector('.ant-modal-body pre');
      if (!title || !message) return null;
      const key = Object.keys(panel).find(name => name.startsWith('__reactFiber$') || name.startsWith('__reactInternalInstance$'));
      // The two NPG customer-notice frontends pass m to the automatic popup component.
      // The notice center's drawer, tabs and inline notice details use separate components.
      for (let fiber = panel[key], depth = 0; fiber && depth < 48; fiber = fiber.return, depth++) {
        const model = fiber.memoizedProps?.m;
        if (!(typeof model?.id === 'string' && model.id || Number.isSafeInteger(model?.id))
          || typeof model.type !== 'string' || typeof model.title !== 'string' || typeof model.content !== 'string') continue;
        const name = tidy(model.title), suffix = title.slice(name.length);
        if (name && title.startsWith(name)
          && (!suffix || /^ [（(](?:\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}:\d{2})?|null)[）)]$/.test(suffix))
          && message.textContent === model.content) return String(model.id);
      }
      return null;
    };

    const findClose = panel => {
      if (interacted.has(panel) || panel.closest('.ga-verify-modal,.ant-drawer,.el-dialog__wrapper')
        || panel.querySelector('.ant-btn-loading,.ant-spin-spinning,[aria-busy="true"],.ant-select-open,[aria-expanded="true"],.ant-select-selection-item,.ant-select-selection-selected-value,.ant-select-selection__choice')) return;
      const untouched = [...panel.querySelectorAll(fields)].filter(visible).every(control => {
        if (control.matches('textarea')) return ['备注', 'Note'].includes(control.placeholder.trim()) && !control.value && !control.defaultValue;
        const select = control.closest('.ant-select');
        const placeholder = select?.querySelector('.ant-select-selection-placeholder,.ant-select-selection__placeholder');
        return tidy(placeholder?.textContent) === '处理结果' && !(control.value ?? '') &&
          control.matches('[role="combobox"],input[type="text"],input[type="search"]');
      });
      if (!untouched) return;
      const close = [...panel.querySelectorAll('button.ant-modal-close[type="button"]')]
        .filter(node => visible(node) && !node.closest('a[href],[aria-disabled="true"],[disabled]'));
      return close.length === 1 ? close[0] : undefined;
    };

    const dismiss = () => {
      timer = null;
      const panels = [...document.querySelectorAll(dialogs)].filter(visible);
      const modals = panels.filter(panel => panel.matches('.ant-modal-content'));
      if (!modals.length || panels.some(panel => !modals.some(modal => panel === modal || panel.contains(modal))) || !npgSession()) return;
      const notices = modals.map(panel => ({ panel, id: autoNotice(panel), close: findClose(panel) }));
      if (notices.some(notice => !notice.id || !notice.close)) return;
      for (const { panel, id, close } of notices) {
        if (attempted.get(panel) === id) continue;
        attempted.set(panel, id);
        close.click();
        setTimeout(() => {
          if (!visible(panel)) window.webkit?.messageHandlers?.smsNPGAutomaticNotice?.postMessage('closed');
        }, 450);
      }
    };

    let timer = null;
    let running = false;
    const schedule = () => { if (timer === null) timer = setTimeout(dismiss, 0); };
    const nearDialog = node => node.nodeType === 1 && (node.closest(modalTree) || node.querySelector(modalTree));
    const observer = new MutationObserver(records => {
      if (records.some(record => record.target.parentElement?.closest(modalTree) || record.target.matches?.(modalTree)
        || [...record.addedNodes, ...record.removedNodes].some(nearDialog))) schedule();
    });
    const protectInput = event => {
      if (!event.isTrusted) return;
      const panel = event.target.closest?.('.ant-modal-content');
      if (panel && event.target.closest(fields)) interacted.add(panel);
    };
    const inputEvents = ['pointerdown', 'keydown', 'input', 'change'];
    window.__smsNPGAutomaticNotice = {
      start() {
        if (!running) {
          running = true;
          observer.observe(document.documentElement, {
            childList: true, subtree: true, characterData: true, attributes: true,
            attributeFilter: ['class', 'style', 'aria-hidden', 'disabled', 'aria-disabled'],
          });
          for (const type of inputEvents) document.addEventListener(type, protectInput, true);
        }
        schedule();
      },
      stop() {
        running = false;
        observer.disconnect();
        clearTimeout(timer);
        timer = null;
        for (const type of inputEvents) document.removeEventListener(type, protectInput, true);
      },
    };
    window.__smsNPGAutomaticNotice.start();
    """#
}
