import AppKit
import WebKit

enum PlatformFileUploadPanel {
  static func present(
    for webView: WKWebView,
    parameters: WKOpenPanelParameters,
    completionHandler: @escaping ([URL]?) -> Void
  ) {
    // Never attach a background page's file request to another platform window.
    guard let window = webView.window, window.isVisible, window.attachedSheet == nil else {
      completionHandler(nil)
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择上传文件"
    panel.prompt = "选择"
    panel.canChooseFiles = !parameters.allowsDirectories
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canCreateDirectories = false
    panel.beginSheetModal(for: window) { response in
      completionHandler(response == .OK ? panel.urls : nil)
    }
  }
}
