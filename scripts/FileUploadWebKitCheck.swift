import AppKit
import WebKit

@MainActor
final class FileUploadCheck: NSObject, WKNavigationDelegate {
  let page: WKWebView
  let delegate = ProductionUploadDelegate()
  let window: NSWindow
  let cases: [(String, String, Bool, Bool)] = [
    ("hidden single", "<input id='file' type='file' accept='.csv,.xlsx' hidden><button onclick='file.click()'>Import</button>", false, false),
    ("multiple", "<input id='file' type='file' multiple hidden><button onclick='file.click()'>Import</button>", true, false),
    ("directory", "<input id='file' type='file' webkitdirectory hidden><button onclick='file.click()'>Import</button>", false, true),
    ("iframe", "<iframe style='border:0;width:500px;height:250px' srcdoc=\"<input id='file' type='file' hidden><button style='width:160px;height:60px' onclick='file.click()'>Import</button>\"></iframe>", false, false)
  ]
  var index = 0
  var polls = 0

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: configuration)
    window = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    page.uiDelegate = delegate
    page.navigationDelegate = self
    window.contentView = page
    window.title = "File selection check (local fixture only)"
  }

  func start() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    loadCase()
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { self.fail("Timed out at " + self.cases[self.index].0) }
  }

  func loadCase() {
    polls = 0
    page.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"connect-src 'none'; form-action 'none'; default-src 'unsafe-inline' data: blob:\"><style>button{width:160px;height:60px}</style></head><body>" + cases[index].1 + "</body></html>", baseURL: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      let point = self.page.convert(NSPoint(x: 60, y: self.page.isFlipped ? 40 : self.page.bounds.height - 40), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
      }
      self.checkPanel()
    }
  }

  func checkPanel() {
    guard let panel = window.attachedSheet as? NSOpenPanel else {
      polls += 1
      guard polls < 100 else { fail("No upload panel for " + cases[index].0); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.checkPanel() }
      return
    }
    let test = cases[index]
    guard panel.canChooseDirectories == test.3,
      panel.canChooseFiles == !test.3,
      (test.3 || panel.allowsMultipleSelection == test.2),
      !panel.canCreateDirectories else { fail("Panel options differ for " + test.0); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      panel.cancel(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.checkCancelled() }
    }
  }

  func checkCancelled() {
    guard window.attachedSheet == nil else { fail("Panel did not close"); return }
    page.evaluateJavaScript("Array.from(document.querySelectorAll('input[type=file]')).concat(Array.from(document.querySelector('iframe')?.contentDocument?.querySelectorAll('input[type=file]') || [])).every(input=>input.files.length===0)") { value, error in
      guard error == nil, value as? Bool == true else { self.fail("Cancel selected a file"); return }
      print("PASS: " + self.cases[self.index].0 + " opens native panel and cancels with no selected files")
      self.index += 1
      if self.index == self.cases.count {
        self.window.orderOut(nil)
        print("PASS: production upload delegate, file/multiple/directory/iframe dialogs; no file read or upload")
        exit(0)
      }
      self.loadCase()
    }
  }

  func fail(_ message: String) {
    print("FAIL: " + message)
    exit(1)
  }
}

@main
struct FileUploadWebKitCheck {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let check = FileUploadCheck()
    check.start()
    app.run()
  }
}
