import Foundation

/// Additional source metadata for existing library text rows. No probing
/// and no inference about playback output or display capabilities.
public enum MediaTechnicalMetadata {
    public static func parts(video: [String: Any], plex: Bool = false, includeCodec: Bool = true) -> [String] {
        func text(_ key: String) -> String {
            (video[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func number(_ key: String) -> Double? {
            let value = (video[key] as? NSNumber)?.doubleValue ?? Double(text(key))
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        var result: [String] = []
        let range = text(plex ? "videoDynamicRange" : "VideoRangeType").lowercased()
        let genericRange = text(plex ? "videoRange" : "VideoRange").lowercased()
        let transfer = text(plex ? "colorTrc" : "ColorTransfer").lowercased()
        // Only explicit valid DV metadata; Main 10, BT.2020 and filenames are not evidence.
        let dv = range != "doviinvalid" && (range.hasPrefix("dovi") || range == "dolbyvision" || range == "dolby vision"
            || number(plex ? "DOVIPresent" : "DvProfile") != nil)
        if dv {
            result.append("Dolby Vision")
        } else if ["hdr10plus", "hdr10+"].contains(range) || genericRange == "hdr10+" {
            result.append("HDR10+")
        } else if range == "hdr10" || genericRange == "hdr10" {
            result.append("HDR10")
        } else if range == "hlg" || genericRange == "hlg" || ["arib-std-b67", "hlg"].contains(transfer) {
            result.append("HLG")
        } else if range == "hdr" || genericRange == "hdr" || ["smpte2084", "smpte-st-2084", "pq"].contains(transfer) {
            result.append("HDR")
        }
        if includeCodec {
            let codec = text(plex ? "codec" : "Codec").lowercased()
            if !codec.isEmpty {
                result.append(["hevc": "HEVC", "h265": "HEVC", "h264": "H.264", "av1": "AV1"][codec] ?? codec.uppercased())
            }
        }
        let fps = plex ? number("frameRate") : (number("RealFrameRate") ?? number("AverageFrameRate"))
        if let fps, fps < 1000 {
            result.append(abs(fps - fps.rounded()) < 0.005 ? String(format: "%.0f fps", fps) : String(format: "%.2f fps", fps))
        }
        if let bits = number(plex ? "bitDepth" : "BitDepth"), bits <= 64, bits.rounded() == bits {
            result.append("\(Int(bits))-bit")
        }
        return result
    }
}
