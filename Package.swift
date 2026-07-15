// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SMSMonitor",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SMSMonitorCore", targets: ["SMSMonitorCore"]),
    .executable(name: "SMSMonitorApp", targets: ["SMSMonitorApp"]),
    .executable(name: "SMSMonitorCoreChecks", targets: ["SMSMonitorCoreChecks"]),
  ],
  targets: [
    .target(name: "SMSMonitorCore"),
    .executableTarget(
      name: "SMSMonitorApp",
      dependencies: ["SMSMonitorCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("Network"),
        .linkedFramework("WebKit"),
        .linkedFramework("UserNotifications"),
      ]
    ),
    .executableTarget(
      name: "SMSMonitorCoreChecks",
      dependencies: ["SMSMonitorCore"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
