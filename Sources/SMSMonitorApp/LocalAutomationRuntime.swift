import Foundation
import Network
import WebKit

private final class LocalAutomationHTTPServer {
  private let queue = DispatchQueue(label: "sms-monitor.local-automation-http")
  private let rootURL: URL
  private let pathToken = UUID().uuidString.lowercased()
  private var listener: NWListener?

  init?(rootURL: URL?) {
    guard let rootURL else { return nil }
    self.rootURL = rootURL
  }

  deinit {
    listener?.cancel()
  }

  func start(completion: @escaping (Result<URL, Error>) -> Void) {
    do {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.newConnectionHandler = { [weak self] connection in
        self?.serve(connection)
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = listener?.port,
            let url = URL(
              string: "http://127.0.0.1:\(port.rawValue)/\(self.pathToken)/runtime.html"
            )
          else {
            DispatchQueue.main.async { completion(.failure(LocalAutomationRuntimeError.runtimeUnavailable)) }
            return
          }
          if ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1" {
            print("Local automation runtime URL: \(url.absoluteString)")
          }
          DispatchQueue.main.async { completion(.success(url)) }
        case .failed(let error):
          DispatchQueue.main.async { completion(.failure(error)) }
        default:
          break
        }
      }
      listener.start(queue: queue)
    } catch {
      completion(.failure(error))
    }
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) {
      [weak self] data, _, _, error in
      guard let self else { return }
      guard error == nil, let data,
        let request = String(data: data, encoding: .utf8),
        let requestLine = request.components(separatedBy: "\r\n").first
      else {
        connection.cancel()
        return
      }
      let parts = requestLine.split(separator: " ")
      if ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1" {
        print("Local automation request: \(requestLine)")
      }
      guard parts.count >= 2, parts[0] == "GET" else {
        self.respond(connection, status: "405 Method Not Allowed", data: Data(), contentType: "text/plain")
        return
      }
      let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
      let prefix = "/\(self.pathToken)/"
      guard path.hasPrefix(prefix) else {
        self.respond(connection, status: "404 Not Found", data: Data(), contentType: "text/plain")
        return
      }
      let relativePath = String(path.dropFirst(prefix.count)).removingPercentEncoding ?? ""
      guard !relativePath.isEmpty, !relativePath.contains("..") else {
        self.respond(connection, status: "400 Bad Request", data: Data(), contentType: "text/plain")
        return
      }
      let fileURL = self.rootURL.appendingPathComponent(relativePath)
      guard let fileData = try? Data(contentsOf: fileURL) else {
        self.respond(connection, status: "404 Not Found", data: Data(), contentType: "text/plain")
        return
      }
      self.respond(
        connection,
        status: "200 OK",
        data: fileData,
        contentType: Self.contentType(for: fileURL.pathExtension)
      )
    }
  }

  private func respond(
    _ connection: NWConnection,
    status: String,
    data: Data,
    contentType: String
  ) {
    let header =
      "HTTP/1.1 \(status)\r\n"
      + "Content-Type: \(contentType)\r\n"
      + "Content-Length: \(data.count)\r\n"
      + "Cache-Control: no-store\r\n"
      + "Connection: close\r\n"
      + "\r\n"
    var response = Data(header.utf8)
    response.append(data)
    connection.send(
      content: response,
      contentContext: .defaultMessage,
      isComplete: true,
      completion: .contentProcessed { error in
        if let error,
          ProcessInfo.processInfo.environment["SMS_MONITOR_LOCAL_AUTOMATION_CHECK"] == "1"
        {
          fputs("Local automation response failed: \(error)\n", stderr)
        }
        self.queue.asyncAfter(deadline: .now() + 0.5) {
          connection.cancel()
        }
      }
    )
  }

  private static func contentType(for fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "wasm": return "application/wasm"
    case "json": return "application/json"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    default: return "application/octet-stream"
    }
  }
}

enum LocalAutomationRuntimeError: LocalizedError {
  case resourceMissing(String)
  case runtimeUnavailable
  case invalidResult
  case operationTimedOut
  case pageOperationTimedOut

  var errorDescription: String? {
    switch self {
    case .resourceMissing(let name):
      return "本地自动登录资源缺失：\(name)"
    case .runtimeUnavailable:
      return "本地验证码识别组件尚未就绪"
    case .invalidResult:
      return "本地自动登录组件返回了无效结果"
    case .operationTimedOut:
      return "本地验证码识别超过 20 秒"
    case .pageOperationTimedOut:
      return "登录页面操作超过 15 秒"
    }
  }
}

final class LocalAutomationRuntime: NSObject, WKNavigationDelegate {
  typealias StringCompletion = (Result<String, Error>) -> Void

  private struct PendingOperation {
    let run: () -> Void
    let fail: (Error) -> Void
  }

  private struct QueuedCall {
    let id: UUID
    let body: String
    let arguments: [String: Any]
    let completion: StringCompletion
  }

  private let server: LocalAutomationHTTPServer?
  private let webView: WKWebView
  private var isReady = false
  private var loadError: Error?
  private var pending: [PendingOperation] = []
  private var queuedCalls: [QueuedCall] = []
  private var activeCallID: UUID?
  private var activeCallTimeout: DispatchWorkItem?

  override init() {
    let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("auto-login")
    let server = LocalAutomationHTTPServer(rootURL: resourceURL)
    self.server = server
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self

    guard let server else {
      loadError = LocalAutomationRuntimeError.resourceMissing("runtime.html")
      return
    }
    server.start { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let runtimeURL):
        self.webView.load(URLRequest(url: runtimeURL))
      case .failure(let error):
        self.loadError = error
        let operations = self.pending
        self.pending.removeAll()
        operations.forEach { $0.fail(error) }
      }
    }
  }

  func recognize(dataURL: String, completion: @escaping StringCompletion) {
    runWhenReady { [weak self] in
      self?.call(
        body: "return await globalThis.localAutomationRuntime.recognize(dataURL);",
        arguments: ["dataURL": dataURL],
        completion: completion
      )
    } onFailure: { error in
      completion(.failure(error))
    }
  }

  func generateTOTP(
    secret: String,
    timestamp: Date = Date(),
    completion: @escaping StringCompletion
  ) {
    runWhenReady { [weak self] in
      self?.call(
        body: "return await globalThis.localAutomationRuntime.generateTotp(secret, timestamp);",
        arguments: [
          "secret": secret,
          "timestamp": timestamp.timeIntervalSince1970 * 1000,
        ],
        completion: completion
      )
    } onFailure: { error in
      completion(.failure(error))
    }
  }

  private func runWhenReady(
    _ operation: @escaping () -> Void,
    onFailure: @escaping (Error) -> Void
  ) {
    if let loadError {
      onFailure(loadError)
      return
    }
    if isReady {
      operation()
      return
    }
    pending.append(PendingOperation(run: operation, fail: onFailure))
  }

  private func call(
    body: String,
    arguments: [String: Any],
    completion: @escaping StringCompletion
  ) {
    queuedCalls.append(
      QueuedCall(id: UUID(), body: body, arguments: arguments, completion: completion)
    )
    runNextCall()
  }

  private func runNextCall() {
    guard isReady, activeCallID == nil, !queuedCalls.isEmpty else { return }
    let call = queuedCalls.removeFirst()
    activeCallID = call.id

    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.activeCallID == call.id else { return }
      self.activeCallID = nil
      self.activeCallTimeout = nil
      call.completion(.failure(LocalAutomationRuntimeError.operationTimedOut))
      self.isReady = false
      self.webView.reload()
    }
    activeCallTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

    webView.callAsyncJavaScript(
      call.body,
      arguments: call.arguments,
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.activeCallID == call.id else { return }
        self.activeCallTimeout?.cancel()
        self.activeCallTimeout = nil
        self.activeCallID = nil
        switch result {
        case .success(let value):
          guard let text = value as? String else {
            call.completion(.failure(LocalAutomationRuntimeError.invalidResult))
            self.runNextCall()
            return
          }
          call.completion(.success(text))
        case .failure(let error):
          call.completion(.failure(error))
        }
        self.runNextCall()
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.callAsyncJavaScript(
      "return await globalThis.localAutomationRuntime.ready();",
      arguments: [:],
      in: nil,
      in: .page
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success:
          self.isReady = true
          let operations = self.pending
          self.pending.removeAll()
          operations.forEach { $0.run() }
          self.runNextCall()
        case .failure(let error):
          self.loadError = error
          let operations = self.pending
          self.pending.removeAll()
          operations.forEach { $0.fail(error) }
        }
      }
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    loadError = error
    let operations = pending
    pending.removeAll()
    operations.forEach { $0.fail(error) }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    loadError = error
    let operations = pending
    pending.removeAll()
    operations.forEach { $0.fail(error) }
  }
}
