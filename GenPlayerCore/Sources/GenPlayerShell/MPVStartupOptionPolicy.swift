import Foundation

/// MPVKit's platform builds do not all include scripting. Disabling a feature
/// which was not compiled in is safe; enabling it or ignoring other errors is not.
enum MPVStartupOptionPolicy {
    static let disabledScripts: [String: String] = [
        "load-scripts": "no", "ytdl": "no", "osc": "no",
        "load-stats-overlay": "no", "load-console": "no",
        "load-auto-profiles": "no", "load-select": "no",
        "load-positioning": "no", "load-commands": "no", "load-context-menu": "no"
    ]

    static func renderingOptions(_ options: [String: String], audioOnly: Bool) -> [String: String] {
        guard audioOnly else { return options }
        var result = options
        result["vid"] = "no"; result["sid"] = "no"; result["secondary-sid"] = "no"
        result["vo"] = "null"
        for key in ["gpu-api", "gpu-context", "target-colorspace-hint"] { result[key] = nil }
        return result
    }

    static func acceptsMissingOption(name: String, value: String) -> Bool {
        value == "no" && disabledScripts[name] != nil
    }

    /// Offscreen PiP requires CPU-readable frames. Keep an explicit software
    /// decoder preference; otherwise request VideoToolbox's copy path.
    static func pixelBufferOptions(_ options: [String: String]) -> [String: String] {
        var result = options
        result["vo"] = "libmpv"
        result["gpu-api"] = nil
        result["gpu-context"] = nil
        result["target-colorspace-hint"] = nil
        result["hwdec"] = options["hwdec"] == "no" ? "no" : "videotoolbox-copy"
        result["profile"] = "sw-fast"
        return result
    }
}

/// HDR requires MPVHDRToneMapper after the high-precision SW render.
public enum MPVPixelBufferColorPolicy {
    public static func supports(transfer: String) -> Bool {
        ["pq", "hlg", "bt.1886", "srgb", "gamma1.8", "gamma2.0", "gamma2.2", "gamma2.4", "gamma2.6", "gamma2.8"]
            .contains(transfer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
