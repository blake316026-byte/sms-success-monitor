import Foundation

struct PersistentHighlightSettings: Codable, Equatable {
  static let defaultColor = "#fff176"
  static let maximumTerms = 200

  var enabled: Bool
  var terms: [String]
  var color: String
  var wholeWords: Bool

  static let defaults = PersistentHighlightSettings(
    enabled: false,
    terms: [],
    color: defaultColor,
    wholeWords: false
  )

  func normalized() -> PersistentHighlightSettings {
    var seen: Set<String> = []
    var normalizedTerms: [String] = []
    for value in terms {
      let term = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
      let key = term.lowercased()
      guard !term.isEmpty, seen.insert(key).inserted else { continue }
      normalizedTerms.append(term)
      if normalizedTerms.count == Self.maximumTerms { break }
    }
    let validColor = color.range(
      of: #"^#[0-9A-Fa-f]{6}$"#,
      options: .regularExpression
    ) != nil
    return PersistentHighlightSettings(
      enabled: enabled,
      terms: normalizedTerms,
      color: validColor ? color.lowercased() : Self.defaultColor,
      wholeWords: wholeWords
    )
  }

  var javascriptValue: [String: Any] {
    let value = normalized()
    return [
      "enabled": value.enabled,
      "terms": value.terms,
      "color": value.color,
      "wholeWords": value.wholeWords,
    ]
  }
}

enum PersistentHighlightScript {
  static let body: String = {
    let url = Bundle.main.resourceURL?
      .appendingPathComponent("auto-login")
      .appendingPathComponent("persistent-highlight.js")
    return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
  }()
}
