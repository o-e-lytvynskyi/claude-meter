import SwiftUI

/// The top of the menu: every limit with its bar and reset, as the Claude app
/// shows them. Built from plain values on each menu open — nothing in it
/// updates while the menu is up.
struct UsageView: View {
    let usage: Usage?
    let failure: String?
    let isFetching: Bool
    let now: Date

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PLAN USAGE LIMITS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let usage {
                ForEach(usage.windows, id: \.title) { row($0) }
            } else {
                Text(isFetching ? "Reading the limits…" : (failure ?? "No limits yet"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(footer)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        // Lines up with the menu items' titles.
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: Self.width, alignment: .leading)
    }

    private func row(_ window: Usage.Window) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text(detail(window))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Bar(share: Double(window.used) / 100, colour: Color(nsColor: StatusIcon.tint(Usage.step(window.used))))
        }
    }

    private func detail(_ window: Usage.Window) -> String {
        guard let resets = window.resets, resets > now else { return "\(window.used)%" }
        // In hours today, as a day and time further off: one short line either way.
        let when = Calendar.current.isDate(resets, inSameDayAs: now) || resets.timeIntervalSince(now) < 6 * 3600
            ? "in \(Format.short(to: resets, from: now))" : Format.when(resets, now: now)
        return "\(window.used)% · resets \(when)"
    }

    private var footer: String {
        if isFetching { return "Updating…" }
        var parts: [String] = []
        if let at = usage?.at { parts.append("Updated \(Format.ago(at, now: now))") }
        if let failure, usage != nil { parts.append("last read failed: \(failure)") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

private struct Bar: View {
    let share: Double
    let colour: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(colour)
                    // A sliver even at 0 %, as the Claude app draws it.
                    .frame(width: max(geo.size.width * min(max(share, 0), 1), 6))
            }
        }
        .frame(height: 6)
    }
}
