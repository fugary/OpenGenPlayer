#if os(macOS)
import SwiftUI
import AppKit
import VLCKitSPM

public enum MacEnvironmentDetector {
    public static let isVirtualMachine: Bool = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let modelString = String(cString: model).lowercased()
            if modelString.contains("virtualmac") || modelString.contains("vmware") || modelString.contains("parallels") || modelString.contains("qemu") {
                return true
            }
        }
        var cpuSize = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &cpuSize, nil, 0)
        if cpuSize > 0 {
            var cpu = [CChar](repeating: 0, count: cpuSize)
            sysctlbyname("machdep.cpu.brand_string", &cpu, &cpuSize, nil, 0)
            let cpuString = String(cString: cpu).lowercased()
            if cpuString.contains("virtualapple") || cpuString.contains("qemu") {
                return true
            }
        }
        return false
    }()
}

public struct MacVLCVideoView: View {
    @ObservedObject var playbackService: MacVLCPlaybackService
    var fillScreen: Bool
    
    public init(playbackService: MacVLCPlaybackService, fillScreen: Bool = false) {
        self.playbackService = playbackService
        self.fillScreen = fillScreen
    }
    
    public var body: some View {
        if playbackService.isUsingMPV {
            if let engine = playbackService.mpvEngine {
                MacMPVVideoView(engine: engine, fillScreen: fillScreen).id(ObjectIdentifier(engine))
            } else { Color.black }
        } else if !PlaybackEngineAvailability.current.vlc {
            Color.black
        } else if MacEnvironmentDetector.isVirtualMachine {
            MacCoreAnimationVideoView(playbackService: playbackService, fillScreen: fillScreen)
        } else {
            MacVLCOpenGLVideoView(playbackService: playbackService, fillScreen: fillScreen,
                                 sessionID: playbackService.vlcVideoViewID)
                .id(playbackService.vlcVideoViewID)
        }
    }
}
#endif
