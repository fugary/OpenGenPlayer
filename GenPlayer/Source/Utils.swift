import Foundation

func formatRuntime(_ minutes: Int) -> String {
    let safeMinutes = max(0, minutes)
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = safeMinutes >= 60 ? [.hour, .minute] : [.minute]
    formatter.zeroFormattingBehavior = .dropAll

    if let formatted = formatter.string(from: TimeInterval(safeMinutes * 60)), !formatted.isEmpty {
        return formatted
    }

    return "0 \(NSLocalizedString("Minutes", comment: ""))"
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
