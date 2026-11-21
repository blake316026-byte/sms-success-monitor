import Foundation
import CryptoKit
import Darwin

struct PendingOrderAlertSettings: Codable, Equatable {
  var enabled = false
  var minutes = 20
  var lookbackDays = 7
  var token = ""
  var chatID = ""
  // nil exists only when decoding the pre-selection settings.
  var selectedPlatformIDs: [String]? = []

  func validate() throws {
    if let ids = selectedPlatformIDs {
      guard ids.count <= 10000, Set(ids).count == ids.count,
        ids.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else {
        throw PendingOrderAlertError.message("报警平台选择格式无效")
      }
    }
    guard (1...10080).contains(minutes), (1...30).contains(lookbackDays) else {
      throw PendingOrderAlertError.message("报警分钟数须为 1–10080，查询天数须为 1–30")
    }
    if enabled {
      guard token.range(of: "^[0-9]{5,20}:[A-Za-z0-9_-]{20,100}$", options: .regularExpression) != nil,
        chatID.range(of: "^-[0-9]{5,20}$", options: .regularExpression) != nil else {
        throw PendingOrderAlertError.message("请填写有效的机器人 Token 和群 ID（负数）")
      }
    }
  }
}

enum PendingOrderAlertError: Error, LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct PendingOrderAlertRecord: Codable {
  var key: String
  var platform: String
  var orderID: String
  var at: Date
  var state: String
  var messageID: String? = nil
}

struct PendingOrderAlertData: Codable {
  var version = 2
  var settings = PendingOrderAlertSettings()
  var records: [PendingOrderAlertRecord] = []
  var lastClock = Date.distantPast
}

enum PendingOrderAlertRules {
  static let retention: TimeInterval = 86400
  static let freshness: TimeInterval = 120
  static func day(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 28800)
    f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
  }
  static func key(scope: String, order: String, now: Date) -> String {
    let data = try! JSONEncoder().encode([scope, order, day(now)])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func eligible(created: Date?, observed: Date?, now: Date, minutes: Int) -> Bool {
    guard let created, let observed, created.timeIntervalSince1970 >= 946684800,
      created <= observed, observed <= now, now.timeIntervalSince(observed) <= freshness else { return false }
    return now.timeIntervalSince(created) > Double(minutes) * 60
  }
  static func clean(_ text: String, limit: Int = 90) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0)
      && !CharacterSet(charactersIn: "\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) }).prefix(limit))
  }
}

// A separate encrypted store and process lock never alter account or login storage.
final class PendingOrderAlertStore {
  private let directory: URL
  private var descriptor: Int32 = -1
  private var key: SymmetricKey!
  private let file: URL
  init(directory: URL) throws {
    self.directory = directory.appendingPathComponent("withdrawal-alerts-v1", isDirectory: true)
    file = self.directory.appendingPathComponent("state.encrypted")
    let fm = FileManager.default
    try fm.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    descriptor = Darwin.open(self.directory.appendingPathComponent("sender.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
      throw PendingOrderAlertError.message("另一个客户端正在使用此报警配置；本窗口不会发送")
    }
    do {
      let keyURL = self.directory.appendingPathComponent("key")
      if fm.fileExists(atPath: keyURL.path) {
        let data = try Data(contentsOf: keyURL)
        guard data.count == 32 else { throw PendingOrderAlertError.message("报警密钥损坏，已停止发送") }
        key = SymmetricKey(data: data)
      } else {
        guard !fm.fileExists(atPath: file.path) else { throw PendingOrderAlertError.message("报警密钥缺失，已停止发送") }
        key = SymmetricKey(size: .bits256)
        try durableWrite(key.withUnsafeBytes { Data($0) }, to: keyURL)
      }
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      var url = self.directory; try url.setResourceValues(values)
    } catch { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1; throw error }
  }
  deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
  func load() throws -> PendingOrderAlertData {
    guard FileManager.default.fileExists(atPath: file.path) else { return PendingOrderAlertData() }
    let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
    var data = try JSONDecoder().decode(PendingOrderAlertData.self, from: AES.GCM.open(sealed, using: key))
    guard [1, 2].contains(data.version), data.version == 1 || data.settings.selectedPlatformIDs != nil else {
      throw PendingOrderAlertError.message("报警记录版本不兼容，已停止发送")
    }
    try data.settings.validate()
    for i in data.records.indices where data.records[i].state == "发送中" { data.records[i].state = "发送待确认" }
    return data
  }
  func save(_ value: PendingOrderAlertData) throws {
    guard let data = try AES.GCM.seal(JSONEncoder().encode(value), using: key).combined else {
      throw PendingOrderAlertError.message("报警记录加密失败")
    }
    try durableWrite(data, to: file)
  }
  private func durableWrite(_ data: Data, to url: URL) throws {
    let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
    try handle.synchronize()
    guard Darwin.rename(temporary.path, url.path) == 0 else { throw PendingOrderAlertError.message("报警记录保存失败") }
    let fd = Darwin.open(directory.path, O_RDONLY); defer { if fd >= 0 { Darwin.close(fd) } }
    guard fd >= 0, fsync(fd) == 0 else { throw PendingOrderAlertError.message("报警记录无法持久保存，已停止发送") }
  }
}

final class PendingOrderAlertLedger {
  private(set) var data: PendingOrderAlertData
  private let save: (PendingOrderAlertData) throws -> Void
  init(data: PendingOrderAlertData, save: @escaping (PendingOrderAlertData) throws -> Void) {
    self.data = data; self.save = save
  }
  private func commit(_ next: PendingOrderAlertData) throws { try save(next); data = next }
  func configure(_ settings: PendingOrderAlertSettings) throws {
    try settings.validate()
    guard settings.selectedPlatformIDs != nil else { throw PendingOrderAlertError.message("报警平台选择尚未初始化") }
    var next = data; next.version = 2; next.settings = settings; try commit(next)
  }
  func prune(now: Date) throws {
    guard now >= data.lastClock.addingTimeInterval(-60) else {
      throw PendingOrderAlertError.message("系统时间回退，已暂停报警，请校准时间")
    }
    var next = data
    next.records.removeAll { now.timeIntervalSince($0.at) >= PendingOrderAlertRules.retention }
    next.lastClock = max(now, next.lastClock)
    try commit(next)
  }
  func reserve(scope: String, platform: String, orders: [String], now: Date) throws -> [PendingOrderAlertRecord] {
    try prune(now: now)
    var next = data; var keys = Set(next.records.map(\.key)); var added: [PendingOrderAlertRecord] = []
    for order in orders {
      let key = PendingOrderAlertRules.key(scope: scope, order: order, now: now)
      guard keys.insert(key).inserted else { continue }
      added.append(PendingOrderAlertRecord(key: key, platform: platform, orderID: order, at: now, state: "发送中"))
    }
    if !added.isEmpty { next.records += added; try commit(next) }
    return added
  }
  func complete(keys: Set<String>, state: String, messageID: String?) throws {
    var next = data
    for i in next.records.indices where keys.contains(next.records[i].key) {
      next.records[i].state = state; next.records[i].messageID = messageID
    }
    try commit(next)
  }
}

final class PendingOrderTelegramTransport: NSObject, URLSessionTaskDelegate {
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
    config.httpCookieStorage = nil; config.urlCache = nil
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  func send(settings: PendingOrderAlertSettings, text: String, completion: @escaping (String, String?) -> Void) {
    var request = URLRequest(url: URL(string: "https://api.telegram.org/bot" + settings.token + "/sendMessage")!)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": settings.chatID, "text": text])
    session.dataTask(with: request) { data, response, error in
      var state = "发送待确认", messageID: String?
      if error == nil, let response = response as? HTTPURLResponse,
        let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if response.statusCode == 200, result["ok"] as? Bool == true,
          let message = result["result"] as? [String: Any], let id = message["message_id"] as? NSNumber {
          state = "已发送"; messageID = id.stringValue
        } else if result["ok"] as? Bool == false, (400..<500).contains(response.statusCode) { state = "发送失败（当天不重发）" }
      }
      DispatchQueue.main.async { completion(state, messageID) }
    }.resume()
  }
  func stop() { session.invalidateAndCancel() }
}
