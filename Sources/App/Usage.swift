import Foundation
import Observation

struct DayUsage: Codable, Hashable {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
}

struct ProviderUsage: Codable, Hashable {
    var days: [String: DayUsage] = [:]            // "yyyy-MM-dd" (Pacific time, matching Google's daily reset)
    var minuteStamps: [Date] = []                 // request times in the last minute
    var perModelToday: [String: Int] = [:]
    var perModelDay: String = ""
    var rateLimit: RateLimitInfo?
    var lastLimitError: String?
    var lastLimitErrorAt: Date?
}

@MainActor
@Observable
final class UsageTracker {
    var providers: [String: ProviderUsage] = [:]

    init() {
        if let data = try? Data(contentsOf: Paths.usageFile),
           let p = try? JSONDecoder().decode([String: ProviderUsage].self, from: data) { providers = p }
    }

    static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return f.string(from: d)
    }

    func usage(_ p: ProviderID) -> ProviderUsage { providers[p.rawValue] ?? ProviderUsage() }
    func today(_ p: ProviderID) -> DayUsage { usage(p).days[Self.dayKey()] ?? DayUsage() }
    func requestsLastMinute(_ p: ProviderID) -> Int { usage(p).minuteStamps.filter { $0 > Date().addingTimeInterval(-60) }.count }

    func recordRequest(_ p: ProviderID, model: String) {
        var u = usage(p)
        let key = Self.dayKey()
        u.days[key, default: DayUsage()].requests += 1
        u.minuteStamps = u.minuteStamps.filter { $0 > Date().addingTimeInterval(-60) } + [Date()]
        if u.perModelDay != key { u.perModelToday = [:]; u.perModelDay = key }
        u.perModelToday[model, default: 0] += 1
        // Keep 60 days of history.
        if u.days.count > 60 { for k in u.days.keys.sorted().dropLast(60) { u.days[k] = nil } }
        providers[p.rawValue] = u
        save()
    }

    func recordTokens(_ p: ProviderID, _ t: TokenUsage) {
        var u = usage(p)
        u.days[Self.dayKey(), default: DayUsage()].promptTokens += t.prompt
        u.days[Self.dayKey(), default: DayUsage()].completionTokens += t.completion
        providers[p.rawValue] = u
        save()
    }

    func recordRateLimit(_ p: ProviderID, _ r: RateLimitInfo) {
        var u = usage(p)
        u.rateLimit = r
        providers[p.rawValue] = u
        save()
    }

    func recordLimitError(_ p: ProviderID, _ message: String) {
        var u = usage(p)
        u.lastLimitError = message
        u.lastLimitErrorAt = Date()
        providers[p.rawValue] = u
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(providers) { try? data.write(to: Paths.usageFile) }
    }
}
