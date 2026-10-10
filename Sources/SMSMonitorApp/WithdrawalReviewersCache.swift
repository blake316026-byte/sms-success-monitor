import Foundation

final class WithdrawalReviewersCache {
  struct Person: Codable { let id: String; let name: String; let count: Int }
  struct Entry: Codable {
    let platformID: String
    let sourceURL: String
    let account: String
    let startDate: String
    let endDate: String
    let family: String
    let people: [Person]
    let savedAt: Date
  }
  struct QueryStatus: Codable {
    let platformID: String
    let sourceURL: String
    let account: String
    let startDate: String
    let endDate: String
    let message: String
    let checkedAt: Date
  }
  struct Total: Codable {
    let platformID: String; let sourceURL: String; let account: String
    let startDate: String; let endDate: String; let count: Int; let savedAt: Date
  }
  private struct State: Codable { let entries: [Entry]; let statuses: [QueryStatus]; var totals: [Total]? = nil }
  static let lifetime: TimeInterval = 24 * 60 * 60
  private let url: URL
  private(set) var entries: [Entry] = []
  private var statuses: [QueryStatus] = []
  private var totals: [Total] = []
  private(set) var writeFailed = false

  init(url: URL? = nil, now: Date = Date()) {
    self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SMS Platform Workbench/withdrawal-reviewers-v1.json")
    if let data = try? Data(contentsOf: self.url) {
      if let state = try? JSONDecoder().decode(State.self, from: data) { entries = state.entries; statuses = state.statuses; totals = state.totals ?? [] }
      else if let decoded = try? JSONDecoder().decode([Entry].self, from: data) { entries = decoded }
    }
    prune(now: now)
  }
  @discardableResult func prune(now: Date = Date()) -> Bool {
    let oldCount = entries.count + statuses.count + totals.count
    entries.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime || $0.savedAt > now }
    statuses.removeAll { now.timeIntervalSince($0.checkedAt) >= Self.lifetime || $0.checkedAt > now }
    totals.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime || $0.savedAt > now }
    let changed = entries.count + statuses.count + totals.count != oldCount
    if changed { save() }
    return changed
  }
  func matching(platformID: String, sourceURL: String, account: String, start: String, end: String, now: Date = Date()) -> Entry? {
    prune(now: now)
    return entries.first { $0.platformID == platformID && $0.sourceURL == sourceURL && $0.account == account
      && $0.startDate == start && $0.endDate == end }
  }
  func put(_ entry: Entry, now: Date = Date()) {
    prune(now: now)
    entries.removeAll { $0.platformID == entry.platformID && $0.startDate == entry.startDate && $0.endDate == entry.endDate }
    entries.append(entry); save()
  }
  func status(platformID: String, sourceURL: String, account: String, start: String, end: String) -> QueryStatus? {
    prune()
    return statuses.first { $0.platformID == platformID && $0.sourceURL == sourceURL && $0.account == account
      && $0.startDate == start && $0.endDate == end }
  }
  func putStatus(_ status: QueryStatus) {
    prune()
    statuses.removeAll { $0.platformID == status.platformID && $0.startDate == status.startDate && $0.endDate == status.endDate }
    statuses.append(status); save()
  }
  func total(platformID: String, sourceURL: String, account: String, start: String, end: String) -> Total? {
    prune()
    return totals.first { $0.platformID == platformID && $0.sourceURL == sourceURL && $0.account == account && $0.startDate == start && $0.endDate == end }
  }
  func putTotal(_ total: Total) {
    prune()
    totals.removeAll { $0.platformID == total.platformID && $0.startDate == total.startDate && $0.endDate == total.endDate }
    totals.append(total); save()
  }
  private func save() {
    do {
      let fm = FileManager.default
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      // These are report counts, not credentials. Do not persist browser session context or tokens.
      try JSONEncoder().encode(State(entries: entries, statuses: statuses, totals: totals)).write(to: url, options: [.atomic])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      writeFailed = false
    } catch { writeFailed = true }
  }

  static func verifyPersistence() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("reviewers.json"), now = Date()
    let cache = WithdrawalReviewersCache(url: url, now: now)
    func entry(_ count: Int, _ date: Date = now) -> Entry {
      Entry(platformID: "one", sourceURL: "https://example.invalid", account: "account", startDate: "2026-10-10", endDate: "2026-10-10",
        family: "NPG", people: count > 0 ? [Person(id: "a", name: "a", count: count)] : [], savedAt: date)
    }
    cache.put(entry(12), now: now); cache.put(entry(25), now: now)
    cache.putTotal(Total(platformID: "one", sourceURL: "https://example.invalid", account: "account",
      startDate: "2026-10-10", endDate: "2026-10-10", count: 355, savedAt: now))
    cache.putStatus(QueryStatus(platformID: "two", sourceURL: "https://example.invalid", account: "account",
      startDate: "2026-10-10", endDate: "2026-10-10", message: "Login required", checkedAt: now))
    let restored = WithdrawalReviewersCache(url: url, now: now)
    guard !cache.writeFailed, restored.entries.count == 1, restored.entries[0].people[0].count == 25,
      restored.total(platformID: "one", sourceURL: "https://example.invalid", account: "account", start: "2026-10-10", end: "2026-10-10")?.count == 355,
      restored.total(platformID: "one", sourceURL: "https://example.invalid", account: "other", start: "2026-10-10", end: "2026-10-10") == nil,
      restored.status(platformID: "two", sourceURL: "https://example.invalid", account: "account", start: "2026-10-10", end: "2026-10-10")?.message == "Login required",
      restored.matching(platformID: "one", sourceURL: "https://example.invalid", account: "other", start: "2026-10-10", end: "2026-10-10", now: now) == nil,
      restored.matching(platformID: "one", sourceURL: "https://example.invalid", account: "account", start: "2026-10-09", end: "2026-10-09", now: now) == nil else { return false }
    restored.put(entry(0), now: now)
    guard restored.entries.count == 1, restored.entries[0].people.isEmpty else { return false }
    guard !restored.prune(now: now.addingTimeInterval(lifetime - 1)), restored.prune(now: now.addingTimeInterval(lifetime)),
      WithdrawalReviewersCache(url: url, now: now.addingTimeInterval(lifetime)).entries.isEmpty else { return false }
    restored.put(entry(1, now.addingTimeInterval(10)), now: now)
    return restored.prune(now: now) && restored.entries.isEmpty
  }
}
