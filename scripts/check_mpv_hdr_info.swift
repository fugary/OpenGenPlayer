import Foundation

@main struct CheckMPVHDR {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func info(_ fields: [String: String]) -> MPVHDRInfo {
            MPVHDRInfo(read: { fields[$0] ?? "" })
        }
        func rows(_ value: MPVHDRInfo) -> [String: String] {
            Dictionary(uniqueKeysWithValues: value.rows(localize: { $0 }).map { ($0.key, $0.value) })
        }
        check(!MPVHDRInfo().isHDR, "Unknown source must not be guessed HDR")
        let sdr = info(["video-params/gamma": "bt.1886", "video-params/pixelformat": "yuv420p10"])
        check(!sdr.isHDR && rows(sdr).isEmpty, "10-bit SDR must not show HDR section")
        let hdr = info(["video-params/gamma": "pq", "video-params/primaries": "bt.2020",
                        "video-out-params/gamma": "pq", "video-target-params/gamma": "srgb",
                        "video-target-params/primaries": "bt.709", "hwdec-current": "no"])
        check(hdr.isHDR, "PQ must show HDR diagnostics")
        check(hdr.targetTransfer == "srgb", "Use VO target, not filter output")
        check(rows(hdr)["HDR.Info.Result"] == "HDR.Info.SDRTarget", "Detect SDR target")
        check(rows(hdr)["HDR.Info.Source"] == "HDR (PQ)", "PQ alone is not proof of HDR10 or Dolby Vision")
        check(rows(hdr)["HDR.Info.Decoder"] == "HDR.Info.Software", "Software is not a hardware decoder")
        let hlg = info(["video-params/gamma": "hlg", "video-target-params/gamma": "pq"])
        check(hlg.isHDR && rows(hlg)["HDR.Info.Result"] == "HDR.Info.HDRTarget", "HLG source and PQ target")
        let dv = info(["video-params/colormatrix": "dolbyvision"])
        check(dv.isHDR && rows(dv)["HDR.Info.Source"] == "Dolby Vision", "Recognize DV matrix without guessing a profile")
        check(rows(dv)["HDR.Info.Result"] == "HDR.Info.Unknown", "DV source is not proof of HDR output")
        for transfer in ["", "auto", "unknown", "linear"] {
            let value = info(["video-params/gamma": "pq", "video-target-params/gamma": transfer])
            check(rows(value)["HDR.Info.Result"] == "HDR.Info.Unknown", "Missing and linear targets cannot be declared SDR")
        }
        var display = hdr
        check(rows(display)["HDR.Info.EDR"] == "HDR.Info.Unknown", "Unavailable EDR is not disabled")
        display.layerEDRRequested = true
        check(rows(display)["HDR.Info.EDR"] == "HDR.Info.Yes", "Report layer request separately")
        check(rows(display)["HDR.Info.Result"] == "HDR.Info.SDRTarget", "EDR flag does not override actual SDR target")
        display.layerEDRRequested = false
        check(rows(display)["HDR.Info.EDR"] == "HDR.Info.No", "Report disabled EDR")
        check(display != hdr, "Layer changes must trigger UI refresh even when paused")
        check(rows(display)["HDR.Info.Limit"] == nil && rows(display)["HDR.Info.Note"] == "HDR.Info.Limit", "Keep output limitation visible")
        display = MPVHDRInfo()
        check(rows(display).isEmpty, "Clearing the session removes HDR details")
        check(!hdr.hasHDRTarget && hdr.hasSDRTarget && hlg.hasHDRTarget && !hlg.hasSDRTarget, "Only known HDR render targets light the badge")
        var badges = info(["video-params/gamma": "pq", "hwdec-current": "videotoolbox",
                           "video-params/w": "3840", "video-params/h": "2160", "container-fps": "23.976"])
        badges.codec = "hevc"
        check(badges.technicalBadges == ["HW", "HEVC", "3840×2160", "23.98 fps"], "Badges show reported precision")
        check(MPVHDRInfo().technicalBadges.isEmpty, "Missing decoder must not claim HW")
        for fps in ["nan", "inf", "0", "-1", "100000"] {
            let value = info(["container-fps": fps])
            check(value.frameRate == nil, "Invalid FPS is omitted")
        }
        print("Passed \(checks) HDR classification and output-boundary checks")
    }
}
