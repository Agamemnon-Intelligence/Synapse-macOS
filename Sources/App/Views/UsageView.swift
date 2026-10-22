import SwiftUI
import Charts

struct UsageView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            PageHeader(title: "Usage", subtitle: "Free-tier usage per provider. Groq reports limits live; for others Synapse counts requests.") { EmptyView() }
            VStack(alignment: .leading, spacing: 16) {
                ForEach([ProviderID.google, .groq, .anthropic, .deepseek, .openrouter, .custom], id: \.self) { p in
                    if app.hasKey(p) || !app.usage.usage(p).days.isEmpty {
                        ProviderUsageCard(provider: p)
                    }
                }
                LocalUsageCard()
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .navigationTitle("Usage")
    }
}

struct ProviderUsageCard: View {
    @Environment(AppState.self) private var app
    let provider: ProviderID

    var body: some View {
        let u = app.usage.usage(provider)
        let today = app.usage.today(provider)
        let rpm = app.usage.requestsLastMinute(provider)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(provider.displayName).font(.headline)
                Spacer()
                if let url = provider.usagePageURL {
                    Link(destination: url) { Label("Official usage dashboard", systemImage: "arrow.up.right.square") }
                }
            }

            if let rl = u.rateLimit {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Live limits (from the last reply, \(rl.updatedAt.formatted(.relative(presentation: .named))))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let lim = rl.limitRequests, let rem = rl.remainingRequests {
                        LimitBar(title: "Requests", remaining: rem, limit: lim, reset: rl.resetRequests)
                    }
                    if let lim = rl.limitTokens, let rem = rl.remainingTokens {
                        LimitBar(title: "Tokens", remaining: rem, limit: lim, reset: rl.resetTokens)
                    }
                }
            } else if provider == .google {
                Text("Google doesn't report remaining quota through the API. Free-tier limits differ per model (requests per minute and per day, resetting at midnight Pacific). The counts below are tracked by Synapse; the dashboard link shows Google's exact numbers.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Stat(title: "Requests today", value: "\(today.requests)")
                Stat(title: "Last minute", value: "\(rpm)")
                Stat(title: "Tokens in today", value: today.promptTokens.formatted(.number.notation(.compactName)))
                Stat(title: "Tokens out today", value: today.completionTokens.formatted(.number.notation(.compactName)))
            }

            if let err = u.lastLimitError, let at = u.lastLimitErrorAt {
                Label {
                    VStack(alignment: .leading) {
                        Text("Limit hit \(at.formatted(.relative(presentation: .named)))").fontWeight(.medium)
                        Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }

            if !u.perModelToday.isEmpty && u.perModelDay == UsageTracker.dayKey() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today by model").font(.caption).foregroundStyle(.secondary)
                    ForEach(u.perModelToday.sorted { $0.value > $1.value }, id: \.key) { k, v in
                        HStack { Text(k).font(.callout); Spacer(); Text("\(v) requests").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            }

            let history = u.days.sorted { $0.key < $1.key }.suffix(14)
            if history.count > 1 {
                Chart(Array(history), id: \.key) { day, usage in
                    BarMark(x: .value("Day", String(day.suffix(5))), y: .value("Requests", usage.requests))
                        .foregroundStyle(Theme.accent)
                }
                .frame(height: 140)
            }
        }
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct LimitBar: View {
    let title: String
    let remaining: Int
    let limit: Int
    let reset: String?

    var body: some View {
        let used = max(0, limit - remaining)
        let frac = limit > 0 ? Double(used) / Double(limit) : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(remaining.formatted()) of \(limit.formatted()) left").monospacedDigit()
                if let reset { Text("· resets in \(reset)").foregroundStyle(.secondary) }
            }
            .font(.callout)
            ProgressView(value: frac).tint(frac > 0.85 ? .red : frac > 0.6 ? .orange : Theme.accent)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
    }
}

struct LocalUsageCard: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let today = app.usage.today(.local)
        HStack(spacing: 12) {
            Text("On This Mac").font(.headline)
            Spacer()
            Text("\(today.requests) requests today · no limits").foregroundStyle(.secondary)
        }
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
