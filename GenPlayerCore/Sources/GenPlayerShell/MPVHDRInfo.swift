import Foundation

/// Read-only rendering diagnostics. A renderer target is not proof of the
/// display's physical HDR mode, nor of HDMI Dolby Vision passthrough.
public struct MPVHDRInfo: Equatable {
    public var sourceTransfer = ""
    public var sourcePrimaries = ""
    public var sourceMatrix = ""
    public var sourcePixelFormat = ""
    public var decoder = ""
    public var codec = ""
    public var width = 0
    public var height = 0
    public var frameRate: Double?
    public var targetTransfer = ""
    public var targetPrimaries = ""
    public var layerColorSpace = ""
    public var layerPixelFormat = ""
    public var layerEDRRequested: Bool?

    public init() {}

    init(read: (String) -> String) {
        sourceTransfer = read("video-params/gamma")
        sourcePrimaries = read("video-params/primaries")
        sourceMatrix = read("video-params/colormatrix")
        sourcePixelFormat = read("video-params/pixelformat")
        decoder = read("hwdec-current")
        width = Int(read("video-params/w")) ?? 0
        height = Int(read("video-params/h")) ?? 0
        if let fps = Double(read("container-fps")), fps.isFinite, fps > 0, fps < 1000 {
            frameRate = fps
        }
        // video-out-params describes frames AFTER filters, BEFORE the VO.
        targetTransfer = read("video-target-params/gamma")
        targetPrimaries = read("video-target-params/primaries")
    }

    public var isHDR: Bool {
        ["pq", "hlg"].contains(sourceTransfer.lowercased()) || sourceMatrix.lowercased() == "dolbyvision"
    }

    public var hasHDRTarget: Bool { ["pq", "hlg"].contains(targetTransfer.lowercased()) }

    public var hasSDRTarget: Bool {
        ["bt.1886", "srgb", "gamma1.8", "gamma2.0", "gamma2.2", "gamma2.4", "gamma2.6", "gamma2.8"]
            .contains(targetTransfer.lowercased())
    }

    /// Compact labels describe only reported values, never infer hardware or resolution.
    public var technicalBadges: [String] {
        var values: [String] = []
        if decoder == "no" { values.append("SW") }
        else if !["", "auto", "unknown"].contains(decoder.lowercased()) { values.append("HW") }
        if !codec.isEmpty { values.append(codec.uppercased()) }
        if width > 0, height > 0 { values.append("\(width)×\(height)") }
        if let frameRate { values.append(String(format: "%.2f fps", frameRate)) }
        return values
    }

    public func rows(localize: (String) -> String) -> [(key: String, value: String)] {
        guard isHDR else { return [] }
        let unknown = localize("HDR.Info.Unknown")
        func value(_ raw: String) -> String {
            ["", "auto", "unknown"].contains(raw.lowercased()) ? unknown : raw
        }
        let source = sourceMatrix.lowercased() == "dolbyvision" ? "Dolby Vision" : "HDR (\(sourceTransfer.uppercased()))"
        let status = hasHDRTarget ? localize("HDR.Info.HDRTarget")
            : (hasSDRTarget ? localize("HDR.Info.SDRTarget") : unknown)
        return [
            (localize("HDR.Info.Source"), source),
            (localize("HDR.Info.SourceColor"), "\(value(sourcePrimaries)) · \(value(sourceTransfer))"),
            (localize("HDR.Info.SourcePixels"), value(sourcePixelFormat)),
            (localize("HDR.Info.Decoder"), decoder == "no" ? localize("HDR.Info.Software") : value(decoder)),
            (localize("HDR.Info.Target"), "\(value(targetPrimaries)) · \(value(targetTransfer))"),
            (localize("HDR.Info.Result"), status),
            (localize("HDR.Info.LayerColor"), value(layerColorSpace)),
            (localize("HDR.Info.LayerPixels"), value(layerPixelFormat)),
            (localize("HDR.Info.EDR"), layerEDRRequested.map { localize($0 ? "HDR.Info.Yes" : "HDR.Info.No") } ?? unknown),
            (localize("HDR.Info.Note"), localize("HDR.Info.Limit"))
        ]
    }
}
