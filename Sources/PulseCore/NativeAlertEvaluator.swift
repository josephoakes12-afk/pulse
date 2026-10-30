import Foundation

/// Per-observation state is private to the local cache, not a source event stream.
struct NativeAlertState: Codable, Equatable, Sendable {
    var value: Int64
    var day: String?
    var notifiedDay: String?
    var observedAt: Date
}

struct NativeAlertEvaluation: Sendable {
    var states: [String: NativeAlertState]
    var messages: [String]
}

enum NativeAlertEvaluator {
    static func evaluate(_ observations: AlertObservations, previous: [String: NativeAlertState],
                         initialized: Bool, enabled: Bool, measuredAt: Date) -> NativeAlertEvaluation {
        var states: [String: NativeAlertState] = [:]
        var messages: [String] = []
        let canNotify = initialized && enabled
        for item in observations.counters.prefix(12) {
            guard validID(item.id), item.value >= 0 else { continue }
            let key = "counter:" + item.id
            guard states[key] == nil else { continue }
            let old = previous[key]
            if let old, measuredAt < old.observedAt { states[key] = old; continue }
            if canNotify, let old, item.value > old.value {
                let delta = item.value.subtractingReportingOverflow(old.value)
                if !delta.overflow {
                    let unit = cleanUnit(delta.partialValue == 1 ? item.unitSingular : item.unitPlural, fallback: item.label)
                    messages.append("\(delta.partialValue.formatted()) more \(unit)")
                }
            }
            states[key] = NativeAlertState(value: item.value, day: nil, notifiedDay: nil, observedAt: measuredAt)
        }
        for item in observations.daily.prefix(12) {
            guard validID(item.id), item.today >= 0, item.yesterday >= 0, isCalendarDay(item.day) else { continue }
            let key = "daily:" + item.id
            guard states[key] == nil else { continue }
            let old = previous[key]
            if let old, measuredAt < old.observedAt || item.day < (old.day ?? "") { states[key] = old; continue }
            var notifiedDay = old?.notifiedDay
            if item.today > item.yesterday, notifiedDay != item.day {
                if canNotify, old != nil {
                    let difference = item.today - item.yesterday
                    messages.append("\(cleanUnit(item.label, fallback: "Activity")): \(difference.formatted()) more today than yesterday (\(item.today.formatted()) vs \(item.yesterday.formatted()))")
                }
                // Already ahead at bootstrap or while opted out is consumed, so
                // granting notification permission later never backfills it.
                notifiedDay = item.day
            }
            states[key] = NativeAlertState(value: item.today, day: item.day, notifiedDay: notifiedDay, observedAt: measuredAt)
        }
        return NativeAlertEvaluation(states: states, messages: messages)
    }

    static func title(_ messages: [String]) -> String? {
        guard !messages.isEmpty else { return nil }
        var title = messages.prefix(3).joined(separator: " · ")
        if messages.count > 3 { title += " · +\(messages.count - 3) more changes" }
        return String(title.prefix(300))
    }

    static func isCalendarDay(_ value: String) -> Bool {
        guard value.count == 10, value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func validID(_ value: String) -> Bool {
        let controls = CharacterSet.controlCharacters
        return !value.isEmpty && value.count <= 128 && !value.unicodeScalars.contains(where: { controls.contains($0) })
    }

    private static func cleanUnit(_ value: String, fallback: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = CharacterSet.controlCharacters
        if clean.isEmpty || clean.unicodeScalars.contains(where: { controls.contains($0) }) { return String(fallback.prefix(80)) }
        return String(clean.prefix(80))
    }
}
