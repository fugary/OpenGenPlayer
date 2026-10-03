import Foundation

@main enum EngineAvailabilityChecks {
    static func main() {
        var count = 0
        // Preference, source eligibility, and startup permissions are independent.
        for vlc in [false, true] {
            for mpv in [false, true] {
                let policy = PlaybackEngineAvailability(vlc: vlc, mpv: mpv)
                for supported in [false, true] {
                    for preference in [nil, "vlc", "mpv", "obsolete"] as [String?] {
                        let result = policy.resolve(preferred: preference, supportsMPV: supported)
                        if let result { precondition(policy.allows(result)) }
                        if !vlc && (!mpv || !supported) { precondition(result == nil) }
                        if !mpv && vlc { precondition(result == .vlc) }
                        if !vlc && mpv && supported { precondition(result == .mpv) }
                        if vlc && mpv {
                            let expected: PlaybackEngineID = preference == "vlc" || !supported ? .vlc : .mpv
                            precondition(result == expected)
                        }
                        count += 1
                    }
                }
            }
        }
        let expected = CommandLine.arguments[1]
        precondition(PlaybackEngineAvailability.current.vlc == !expected.contains("vlc"))
        precondition(PlaybackEngineAvailability.current.mpv == !expected.contains("mpv"))
        print("PASS: \(count) routing cases; startup permissions: \(expected)")
    }
}
