public enum PostLogoutLoginPolicy {
  public static func shouldResume(signedOutUsername: String, configuredUsername: String, canAutoLogin: Bool) -> Bool {
    canAutoLogin && !signedOutUsername.isEmpty && signedOutUsername == configuredUsername
  }
}
