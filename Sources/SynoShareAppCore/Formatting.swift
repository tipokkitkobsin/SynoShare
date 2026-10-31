import Foundation

/// Number formatting for the UI (binary units, like Finder's "GiB" figures in the CLI report).
public enum Formatting {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    private static let secondsPerDay = 86_400
    private static let daysPerMonth = 30
    private static let daysPerYear = 365

    /// "12s", "4m 09s", "1h 05m", "7d 12h", "1mo 05d", "> 1 year"; "—" when unknown.
    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        // Compare as Double first: a near-zero speed gives values far beyond Int.max.
        guard seconds < Double(daysPerYear * secondsPerDay) else { return "> 1 year" }
        let total = Int(seconds.rounded())
        let days = total / secondsPerDay
        let (hours, minutes, secs) = (total / 3600 % 24, total / 60 % 60, total % 60)
        if days >= daysPerMonth {
            return String(format: "%dmo %02dd", days / daysPerMonth, days % daysPerMonth)
        }
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }

    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }

    /// Last path component of a remote path, for compact lists.
    public static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
