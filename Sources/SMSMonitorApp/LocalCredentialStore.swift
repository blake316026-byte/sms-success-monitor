import CryptoKit
import Foundation

struct LocalLoginProfile: Codable, Equatable {
  var username: String
  var password: String
  var totpSecret: String
  var token: String
  var autoLoginEnabled: Bool

  var canAutoLogin: Bool {
    autoLoginEnabled
      && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !password.isEmpty
  }
}

final class LocalCredentialStore {
  private static let lock = NSLock()

  private let fileManager = FileManager.default
  private let directoryURL: URL
  private let keyURL: URL
  private let profilesURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init() {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    directoryURL = base.appendingPathComponent("SMS Success Monitor", isDirectory: true)
    keyURL = directoryURL.appendingPathComponent("credentials-v3.key")
    profilesURL = directoryURL.appendingPathComponent("credentials-v3.dat")
  }

  func profile(for moduleID: String, allowInteraction _: Bool = false) -> LocalLoginProfile? {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return loadProfiles()[moduleID]
  }

  @discardableResult
  func save(
    _ profile: LocalLoginProfile,
    for moduleID: String,
    allowInteraction _: Bool = false
  ) -> Bool {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var profiles = loadProfiles()
    profiles[moduleID] = profile
    return persist(profiles)
  }

  func updateToken(_ token: String, for moduleID: String) {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var profiles = loadProfiles()
    guard var profile = profiles[moduleID] else { return }
    let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized != profile.token else { return }
    profile.token = normalized
    profiles[moduleID] = profile
    _ = persist(profiles)
  }

  func remove(moduleID: String) {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var profiles = loadProfiles()
    if profiles.removeValue(forKey: moduleID) != nil {
      _ = persist(profiles)
    }
  }

  private func loadProfiles() -> [String: LocalLoginProfile] {
    guard
      let key = encryptionKey(),
      let encrypted = try? Data(contentsOf: profilesURL),
      let box = try? AES.GCM.SealedBox(combined: encrypted),
      let plaintext = try? AES.GCM.open(box, using: key),
      let profiles = try? decoder.decode([String: LocalLoginProfile].self, from: plaintext)
    else {
      return [:]
    }
    return profiles
  }

  private func persist(_ profiles: [String: LocalLoginProfile]) -> Bool {
    guard
      prepareDirectory(),
      let key = encryptionKey(),
      let plaintext = try? encoder.encode(profiles),
      let encrypted = try? AES.GCM.seal(plaintext, using: key).combined
    else {
      return false
    }
    do {
      try encrypted.write(to: profilesURL, options: .atomic)
      try protect(profilesURL, permissions: 0o600)
      return true
    } catch {
      return false
    }
  }

  private func encryptionKey() -> SymmetricKey? {
    if let data = try? Data(contentsOf: keyURL), data.count == 32 {
      return SymmetricKey(data: data)
    }
    guard prepareDirectory() else { return nil }
    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }
    do {
      try data.write(to: keyURL, options: .atomic)
      try protect(keyURL, permissions: 0o600)
      return key
    } catch {
      return nil
    }
  }

  private func prepareDirectory() -> Bool {
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try protect(directoryURL, permissions: 0o700)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableURL = directoryURL
      try? mutableURL.setResourceValues(values)
      return true
    } catch {
      return false
    }
  }

  private func protect(_ url: URL, permissions: Int) throws {
    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }
}
