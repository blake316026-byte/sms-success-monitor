import Foundation

public enum TOTPSecretPolicy {
  public static func isValid(_ value: String) -> Bool {
    guard let secret = extractedSecret(from: value) else { return false }
    let normalized = secret
      .uppercased()
      .filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
    return !normalized.isEmpty && normalized.allSatisfy {
      $0.isASCII && ($0.isLetter || ("2"..."7").contains(String($0)))
    }
  }

  private static func extractedSecret(from value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.lowercased().hasPrefix("otpauth://") else { return trimmed }
    guard
      let components = URLComponents(string: trimmed),
      let secret = components.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value,
      !secret.isEmpty
    else { return nil }
    return secret
  }
}
