import Foundation

public enum PlatformRoutingPolicy {
  private static let monitoredCustomDomains = [
    "npgaaa.com",
    "sixsass.com",
  ]

  public static func shouldUseNPGMonitoring(
    configurationID: String,
    targetURL: URL
  ) -> Bool {
    guard configurationID.hasPrefix("custom-") else { return true }
    guard let host = targetURL.host?.lowercased() else { return false }

    return monitoredCustomDomains.contains { domain in
      host == domain || host.hasSuffix(".\(domain)")
    }
  }
}
