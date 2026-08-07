import Foundation
import SMSMonitorCore

enum LocalModuleConfigurationStore {
  private struct ModuleRecord: Decodable {
    let id: String
    let name: String?
    let url: String
  }

  static let configurationURL: URL = {
    let baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser

    return baseDirectory
      .appendingPathComponent("SMS Success Monitor", isDirectory: true)
      .appendingPathComponent("modules-v1.json", isDirectory: false)
  }()

  static func loadConfigurations(fallback: [MonitorConfiguration]) -> [MonitorConfiguration] {
    guard let data = try? Data(contentsOf: configurationURL),
      let records = try? JSONDecoder().decode([ModuleRecord].self, from: data)
    else {
      return fallback
    }

    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    return fallback.map { configuration in
      guard let record = recordsByID[configuration.id],
        let url = URL(string: record.url),
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else {
        return configuration
      }

      let configuredName = record.name?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return MonitorConfiguration(
        id: configuration.id,
        displayName: configuredName.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.displayName,
        targetURL: url,
        profileIdentifier: configuration.profileIdentifier,
        sampleLimit: configuration.sampleLimit,
        scanInterval: configuration.scanInterval,
        alertThreshold: configuration.alertThreshold
      )
    }
  }
}
