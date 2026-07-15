import Foundation
import LocalAuthentication
import Security

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
  // v2 intentionally leaves the legacy ad-hoc-signature items untouched.
  // Accessing those items triggers an unavoidable macOS ACL prompt after an
  // app rebuild. New items are created under the stable designated identity.
  private let service = "com.local.sms-success-monitor.credentials.v2"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  func profile(for moduleID: String, allowInteraction: Bool = false) -> LocalLoginProfile? {
    var query = baseQuery(moduleID: moduleID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    applyInteractionPolicy(to: &query, allowInteraction: allowInteraction)

    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else {
      return nil
    }
    return try? decoder.decode(LocalLoginProfile.self, from: data)
  }

  @discardableResult
  func save(
    _ profile: LocalLoginProfile,
    for moduleID: String,
    allowInteraction: Bool = false
  ) -> Bool {
    guard let data = try? encoder.encode(profile) else { return false }
    var query = baseQuery(moduleID: moduleID)
    applyInteractionPolicy(to: &query, allowInteraction: allowInteraction)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }

    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  func updateToken(_ token: String, for moduleID: String) {
    guard var profile = profile(for: moduleID) else { return }
    let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized != profile.token else { return }
    profile.token = normalized
    _ = save(profile, for: moduleID)
  }

  func remove(moduleID: String) {
    SecItemDelete(baseQuery(moduleID: moduleID) as CFDictionary)
  }

  private func baseQuery(moduleID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: moduleID,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  private func applyInteractionPolicy(
    to query: inout [String: Any],
    allowInteraction: Bool
  ) {
    guard !allowInteraction else { return }
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
  }
}
