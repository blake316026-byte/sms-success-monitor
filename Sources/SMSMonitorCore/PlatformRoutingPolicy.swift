import Foundation

public enum PlatformRoutingPolicy {
  private static let monitoredCustomDomains = [
    "fpljsoft.com",
    "npgaaa.com",
    "sixsass.com",
  ]
  private static let monitoredCustomHosts = [
    "c2-gyk2yh.npgqwe.com",
  ]

  public static func shouldUseNPGMonitoring(
    configurationID: String,
    targetURL: URL
  ) -> Bool {
    guard configurationID.hasPrefix("custom-") else { return true }
    guard let host = targetURL.host?.lowercased() else { return false }

    return monitoredCustomHosts.contains(host) || monitoredCustomDomains.contains { domain in
      host == domain || host.hasSuffix(".\(domain)")
    }
  }
}
