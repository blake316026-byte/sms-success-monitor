public enum PostLogoutLoginPolicy {
  public static func shouldResume(
    signedOutUsername: String,
    loginPageUsername: String = "",
    configuredUsername: String,
    canAutoLogin: Bool
  ) -> Bool {
    guard canAutoLogin else { return false }
    let observedUsername = signedOutUsername.isEmpty ? loginPageUsername : signedOutUsername
    return !observedUsername.isEmpty && observedUsername == configuredUsername
  }
}
