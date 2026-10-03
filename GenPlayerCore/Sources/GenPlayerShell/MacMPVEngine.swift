#if os(macOS) || os(iOS) || os(tvOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Network
import Libmpv
import GenPlayerMPVBridge
import Metal
import SwiftUI

/// Client API access, including destruction, is serialized off the UI thread.
/// The iOS simulator has a separate render queue, as required by libmpv.
/// No libmpv callbacks retain an unowned Swift pointer.
public final class MPVPlaybackEngine {
    public typealias Track = MacMPVTrack

    public struct Failure {
        public enum Stage: String {
            case create, option, surface, stream, initialize, load, playback, frameOutput, shutdown
        }
        public let stage: Stage
        public let code: Int32?
        public var isInitialization: Bool {
            switch stage {
            case .create, .option, .surface, .stream, .initialize: return true
            case .load, .playback, .frameOutput, .shutdown: return false
            }
        }
    }

    public struct State: Equatable {
        public var time: Double = 0
        public var duration: Double = 0
        public var bufferedBytes: Int64 = 0
        public var bufferedRanges: [MPVBufferedRange] = []
        #if os(macOS) || os(iOS) || os(tvOS)
        public var cacheInputBytesPerSecond: Int64?
        public var cacheReadIdle = false
        #endif
        #if os(macOS) || os(iOS)
        public var diskCacheMode: MacMPVDiskCacheMode = .inactive
        public var diskCacheBytes: Int64 = 0
        public var diskCacheReason: MacMPVDiskCacheReason?
        #endif
        public var paused = false
        public var buffering = true
        public var loaded = false
        public var seekable = false
        public var ended = false
        public var size: CGSize = .zero
        public var videoTransfer = ""
        public var audio = -1
        public var subtitle = -1
        public var secondary = -1
        public var secondaryText = ""
        public var secondaryASSBounds: CGRect?
        public var secondaryASSHasContent = false
        #if os(iOS) || os(tvOS) || os(macOS)
        public var secondaryStart: Double?
        public var secondaryEnd: Double?
        #endif
        public var primaryText = ""
        public var primaryStart: Double?
        public var primaryEnd: Double?
        public var metadata: [String: String] = [:]
        public var tracks: [Track] = []
        public var hdrInfo = MPVHDRInfo()
    }

    public struct Configuration {
        public let url: URL
        public let start: Double
        public var startPercentage: Double? = nil
        public let options: [String: String]
        public let readAheadCache: Bool
        public let subtitles: [URL]
        public var audioOnly = false
        public var stream: MacMPVStream? = nil
        #if os(iOS) || os(tvOS) || os(macOS)
        public var pixelBufferOutput: MPVPixelBufferOutput? = nil
        #endif
        public init(url: URL, start: Double, options: [String: String], subtitles: [URL],
                    audioOnly: Bool = false, stream: MacMPVStream? = nil, readAheadCache: Bool = false) {
            self.url = url; self.start = start; self.options = options; self.subtitles = subtitles
            self.audioOnly = audioOnly; self.stream = stream; self.readAheadCache = readAheadCache
        }
    }

    private let core: Core
    #if os(macOS)
    weak var videoView: NSView?
    #else
    public lazy var videoSurfaceView = MPVVideoSurfaceView(engine: self)
    #endif

    public init(configuration: Configuration, onState: @escaping (State) -> Void, onError: @escaping (Failure) -> Void) {
        let observation = PlaybackTransportObservation()
        transportObservation = observation
        core = Core(configuration: configuration, onState: { state in
            let phase: PlaybackTransportState.Phase = state.ended ? .ended :
                (state.paused ? .paused : (!state.loaded || state.buffering ? .loading : .playing))
            observation.update(.init(phase: phase, position: state.time, duration: state.duration,
                seekable: state.seekable, audioTrackID: state.audio, subtitleTrackID: state.subtitle))
            onState(state)
        }, onError: { failure in
            observation.fail()
            onError(failure)
        })
    }

    private let transportObservation: PlaybackTransportObservation
    public var transportState: PlaybackTransportState { transportObservation.snapshot }

    public func startAudio() { core.start(layer: nil) }
    #if os(iOS) || os(tvOS) || os(macOS)
    public func startPixelBufferOutput() { core.start(layer: nil) }
    public var usesPixelBufferOutput: Bool { core.usesPixelBufferOutput }
    #endif
    public func attach(to layer: CAMetalLayer) { core.start(layer: layer) }
    #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
    func updateSoftwareSurface(size: CGSize, display: @escaping (CGImage) -> Void) {
        core.softwareRenderer.configure(size: size, display: display)
        core.start(layer: nil)
    }
    #endif
    public func set(_ name: String, _ value: String) { core.set(name, value) }
    public func configureSecondaryASS(track: Int, scale: Double, centerY: Double?) {
        core.configureSecondaryASS(track: track, scale: scale, centerY: centerY ?? -1)
    }
    public func selectSubtitles(primary: Int, secondary: Int, completion: @escaping (Int, Int) -> Void) {
        core.selectSubtitles(primary: primary, secondary: secondary, completion: completion)
    }
    public func seek(seconds: Double) { core.command(["seek", String(max(0, seconds)), "absolute+exact"]) }
    public func removeSubtitle(id: Int) { core.command(["sub-remove", String(id)]) }
    public func addSubtitle(_ url: URL, title: String = "", language: String = "") { core.addSubtitle(url, title: title, language: language) }
    public func addCachedSubtitle(_ url: URL, source: URL) { core.addCachedSubtitle(url, source: source) }
    public func snapshot(completion: @escaping (URL?) -> Void) { core.snapshot(completion: completion) }
    public func stop() { transportObservation.stop(); core.close() }
    deinit { core.close() }

    private final class Core {
        private var secondaryASSStyle = (track: -1, scale: 1.0, centerY: -1.0)
        private let queue = DispatchQueue(label: "com.genplayer.mac.mpv", qos: .userInitiated)
        private let configuration: Configuration
        private let onState: (State) -> Void
        private let onError: (Failure) -> Void
        private var handle: OpaquePointer?
        #if os(macOS) || os(iOS) || os(tvOS)
        private var cacheReadSpeedSmoother = MPVReadSpeedSmoother()
        #endif
        #if os(macOS) || os(iOS)
        private var diskCacheDirectory: URL?
        private var nextDiskCacheCheck: TimeInterval = 0
        private var diskFileBytes: Int64?
        private var diskCacheMonitor = MacMPVDiskCacheMonitor()
        private var cacheNetworkMonitor: NWPathMonitor?
        private var cacheNetworkAllowsReadAhead = false
        private var cacheReadAheadSeconds = "120"
        #if os(iOS)
        private var cacheForeground = false
        private var cacheLifecycleObservers: [NSObjectProtocol] = []
        #endif
        #endif
        private var timer: DispatchSourceTimer?
        private var lastHDRInfoTime: TimeInterval = -.infinity
        private var layer: CAMetalLayer?
        #if os(iOS) || os(tvOS) || os(macOS)
        private var pixelBufferRenderer: MPVSampleBufferRenderer?
        #endif
        var usesPixelBufferOutput: Bool {
            #if os(iOS) || os(tvOS) || os(macOS)
            return !configuration.audioOnly && configuration.pixelBufferOutput != nil
            #else
            return false
            #endif
        }
        #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
        let softwareRenderer = MPVSimulatorRenderer()
        #endif
        private var closed = false
        private var failed = false
        private var started = false
        private var state = State()
        private var tracksDirty = true
        private var cachedSubtitles: [URL] = []
        private var pendingSubtitles: [[String]] = []
        private var subtitleOrigins: [String: URL] = [:]
        private var pendingProperties: [String: String] = [:]
        private var nextRequestID: UInt64 = 2
        private struct SnapshotRequest {
            let url: URL
            var completion: ((URL?) -> Void)?
        }
        private var snapshots: [UInt64: SnapshotRequest] = [:]

        init(configuration: Configuration, onState: @escaping (State) -> Void, onError: @escaping (Failure) -> Void) {
            self.configuration = configuration
            self.onState = onState
            self.onError = onError
        }

        func start(layer: CAMetalLayer?) {
            queue.async { [self] in
                guard !closed, !started else { return }
                guard PlaybackEngineAvailability.current.mpv else { fail(.create); return }
                started = true
                self.layer = layer // Keep the surface alive until libmpv has been destroyed.
                _ = GPMPVMetalContextRevision() // Link the window-resize-aware Metal context.
                guard let handle = mpv_create() else { fail(.create); return }
                self.handle = handle
                let options = [
                    "config": "no",
                    "terminal": "no", "msg-level": "all=no", "osd-level": "0",
                    "input-default-bindings": "no", "input-vo-keyboard": "no",
                    "input-media-keys": "no", "idle": "yes", "keep-open": "yes",
                    "keep-open-pause": "no", "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                    "target-colorspace-hint": "yes", "sub-auto": "no",
                    "secondary-sub-ass-override": "strip"
                ].merging(MPVStartupOptionPolicy.disabledScripts) { _, new in new }
                    .merging(MPVPlaybackCachePolicy.options(enabled: configuration.readAheadCache, url: configuration.url)) { _, new in new }
                    .merging(configuration.options) { _, new in new }
                // macOS must still disable every built-in script to avoid creating
                // LuaJIT states in a hardened host. iOS/tvOS omit Lua entirely.
                var effectiveOptions = options.merging(pendingProperties, uniquingKeysWith: { _, new in new })
                effectiveOptions = MPVStartupOptionPolicy.renderingOptions(effectiveOptions, audioOnly: configuration.audioOnly)
                if usesPixelBufferOutput {
                    effectiveOptions = MPVStartupOptionPolicy.pixelBufferOptions(effectiveOptions)
                }
                #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
                if !configuration.audioOnly && !usesPixelBufferOutput {
                    effectiveOptions["vo"] = "libmpv"
                    effectiveOptions["gpu-api"] = nil
                    effectiveOptions["gpu-context"] = nil
                    effectiveOptions["target-colorspace-hint"] = nil
                    effectiveOptions["hwdec"] = "no"
                    effectiveOptions["vd-lavc-threads"] = "4"
                    effectiveOptions["profile"] = "sw-fast"
                }
                #endif
                for name in effectiveOptions.keys.sorted() {
                    let value = effectiveOptions[name]!
                    let result = mpv_set_option_string(handle, name, value)
                    if result == MPV_ERROR_OPTION_NOT_FOUND.rawValue,
                       MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: value) { continue }
                    guard result >= 0 else { fail(.option, code: result, option: name); return }
                }
                #if os(macOS) || os(iOS)
                configureDiskCache(handle)
                #endif
                if let layer, !usesPixelBufferOutput {
                    var surface = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
                    let result = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &surface)
                    guard result >= 0 else { fail(.surface, code: result); return }
                } else {
                    #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
                    if configuration.audioOnly {
                        let result = mpv_set_option_string(handle, "vo", "null")
                        guard result >= 0 else { fail(.surface, code: result); return }
                    }
                    #else
                    guard configuration.audioOnly || usesPixelBufferOutput else { fail(.surface); return }
                    if configuration.audioOnly {
                        let result = mpv_set_option_string(handle, "vo", "null")
                        guard result >= 0 else { fail(.surface, code: result); return }
                    }
                    #endif
                }
                if let stream = configuration.stream, !stream.register(on: handle) { fail(.stream); return }
                let result = mpv_initialize(handle)
                guard result >= 0 else { fail(.initialize, code: result); return }
                #if os(iOS) || os(tvOS) || os(macOS)
                if usesPixelBufferOutput, let output = configuration.pixelBufferOutput {
                    let renderer = MPVSampleBufferRenderer(output: output)
                    pixelBufferRenderer = renderer
                    let result = renderer.initialize(handle: handle) { [weak self] code in
                        self?.queue.async { [weak self] in self?.fail(.frameOutput, code: code) }
                    }
                    guard result >= 0 else { fail(.surface, code: result); return }
                }
                #endif
                #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
                if !configuration.audioOnly && !usesPixelBufferOutput {
                    let result = softwareRenderer.initialize(handle: handle) { [weak self] code in
                        self?.queue.async { [weak self] in self?.fail(.playback, code: code) }
                    }
                    guard result >= 0 else { fail(.surface, code: result); return }
                    NSLog("[MPV] simulator software renderer initialized (preview long edge <= 1280)")
                }
                #endif
                NSLog("[MPV] initialized")
                mpv_observe_property(handle, 1, "track-list", MPV_FORMAT_NONE)
                let sourceURL = configuration.stream?.url ?? configuration.url
                let path = sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
                let start: String
                if let percentage = configuration.startPercentage, percentage.isFinite {
                    start = "\(min(99, max(0, percentage)))%"
                } else { start = String(configuration.start.isFinite ? max(0, configuration.start) : 0) }
                guard send(["loadfile", path, "replace", "-1", "start=\(start)"], fatal: true) else { return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer
                timer.resume()
            }
        }

        func set(_ name: String, _ value: String) {
            queue.async { [self] in
                guard !closed, !failed else { return }
                if ["secondary-sub-visibility", "secondary-sub-pos", "secondary-sub-delay", "secondary-sub-ass-override"].contains(name),
                   pendingProperties[name] == value { return }
                pendingProperties[name] = value
                if let handle { _ = mpv_set_property_string(handle, name, value) }
            }
        }

        func configureSecondaryASS(track: Int, scale: Double, centerY: Double) {
            queue.async { [self] in
                guard !closed, !failed, let handle else { return }
                guard secondaryASSStyle != (track, scale, centerY) else { return }
                secondaryASSStyle = (track, scale, centerY)
                GPMPVSetSecondaryASS(UnsafeMutableRawPointer(handle), Int64(track), scale, centerY)
                if track >= 0 {
                    // mpv skips notifications for equal values. This option is
                    // ignored with ASS override=no, but changing it requests an
                    // OSD redraw even while paused (on both render backends).
                    let refresh = number("secondary-sub-pos") == 100 ? "99.999" : "100"
                    _ = mpv_set_property_string(handle, "secondary-sub-pos", refresh)
                }
            }
        }

        func selectSubtitles(primary: Int, secondary: Int, completion: @escaping (Int, Int) -> Void) {
            queue.async { [self] in
                guard !closed, !failed, let handle else {
                    DispatchQueue.main.async { completion(-1, -1) }
                    return
                }
                // Release the secondary decoder first, including when swapping the two
                // tracks. mpv refuses to select a track already owned by the other slot.
                for (name, value) in MacMPVSubtitleSelection.operations(primary: primary, secondary: secondary) {
                    _ = mpv_set_property_string(handle, name, value)
                }
                let actualPrimary = Int(string("sid")) ?? -1
                let actualSecondary = Int(string("secondary-sid")) ?? -1
                #if os(iOS) || os(macOS) || os(tvOS)
                GPMPVSetSecondaryASSMirror(UnsafeMutableRawPointer(handle), primary >= 0 && primary == secondary && actualPrimary == primary)
                // Same-track ASS lives in the primary OSD layer. Invalidate it
                // even while paused when enabling/disabling the mirrored layer.
                let position = string("secondary-sub-pos")
                _ = mpv_set_property_string(handle, "secondary-sub-pos", number("secondary-sub-pos") == 100 ? "99.999" : "100")
                _ = mpv_set_property_string(handle, "secondary-sub-pos", position)
                #endif
                DispatchQueue.main.async { completion(actualPrimary, actualSecondary) }
            }
        }

        func addCachedSubtitle(_ url: URL, source: URL) {
            queue.async { [self] in
                guard !closed, !failed else { try? FileManager.default.removeItem(at: url); return }
                cachedSubtitles.append(url)
                subtitleOrigins[url.path] = source
                subtitleOrigins[url.absoluteString] = source
                // May finish before the surface is mounted. FILE_LOADED drains this list.
                if state.loaded { _ = send(["sub-add", url.path, "auto", source.deletingPathExtension().lastPathComponent]) }
            }
        }

        func addSubtitle(_ url: URL, title: String, language: String) {
            queue.async { [self] in
                guard !closed, !failed else { return }
                let args = ["sub-add", url.isFileURL ? url.path : url.absoluteString, "auto", title, language]
                if state.loaded { _ = send(args) }
                else { pendingSubtitles.append(args) }
            }
        }

        func command(_ args: [String]) {
            queue.async { [self] in
                guard !closed, !failed, handle != nil else { return }
                _ = send(args)
            }
        }

        func close() {
            configuration.stream?.cancel()
            queue.async { [self] in
                guard !closed else { return }
                closed = true
                destroy()
            }
        }

        func snapshot(completion: @escaping (URL?) -> Void) {
            queue.async { [self] in
                guard !closed, !failed, state.loaded, snapshots.count < 4 else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                let id = nextRequestID
                nextRequestID &+= 1
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("GenPlayer_mpv_\(UUID().uuidString).png")
                snapshots[id] = SnapshotRequest(url: url, completion: completion)
                #if os(iOS) || os(tvOS) || os(macOS)
                if let renderer = pixelBufferRenderer {
                    renderer.snapshot(to: url) { [self] success in
                        queue.async { [self] in finishSnapshot(id, success: success) }
                    }
                    return
                }
                #endif
                #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
                if !configuration.audioOnly {
                    softwareRenderer.snapshot(to: url) { [self] success in
                        queue.async { [self] in finishSnapshot(id, success: success) }
                    }
                    return
                }
                #endif
                guard send(["screenshot-raw", "window", "rgba"], requestID: id) else {
                    finishSnapshot(id, success: false); return
                }
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, let request = self.snapshots[id], let completion = request.completion else { return }
                    // Retain the temporary path until the async reply or teardown;
                    // a late encoder completion must not leak a file or call back twice.
                    self.snapshots[id]?.completion = nil
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }

        private func handleSnapshotReply(_ id: UInt64, error: Int32, result: mpv_node) {
            guard let request = snapshots[id] else { return }
            if request.completion == nil { finishSnapshot(id, success: false); return }
            guard error >= 0, let frame = captureFrame(result) else {
                finishSnapshot(id, success: false); return
            }
            // PNG encoding uses ImageIO, independently of the two FFmpeg distributions.
            finishSnapshot(id, success: frame.writePNG(to: request.url))
        }

        private func captureFrame(_ node: mpv_node) -> MacMPVCaptureFrame? {
            guard node.format == MPV_FORMAT_NODE_MAP, let map = node.u.list else { return nil }
            var fields: [String: mpv_node] = [:]
            guard map.pointee.num >= 0, map.pointee.num <= 32,
                  let keys = map.pointee.keys, let values = map.pointee.values else { return nil }
            for index in 0..<Int(map.pointee.num) {
                if let key = keys[index] { fields[String(cString: key)] = values[index] }
            }
            func integer(_ key: String) -> Int? {
                guard let value = fields[key], value.format == MPV_FORMAT_INT64 else { return nil }
                return Int(exactly: value.u.int64)
            }
            guard let width = integer("w"), let height = integer("h"), let stride = integer("stride"),
                  let format = fields["format"], format.format == MPV_FORMAT_STRING,
                  let name = format.u.string, String(cString: name) == "rgba",
                  let data = fields["data"], data.format == MPV_FORMAT_BYTE_ARRAY,
                  let bytes = data.u.ba, bytes.pointee.size <= 256 * 1024 * 1024,
                  let pointer = bytes.pointee.data else { return nil }
            return MacMPVCaptureFrame(width: width, height: height, stride: stride,
                pixels: Data(bytes: pointer, count: bytes.pointee.size))
        }

        private func finishSnapshot(_ id: UInt64, success: Bool) {
            guard let request = snapshots.removeValue(forKey: id) else { return }
            let exists = (try? request.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let result = success && exists > 0 && request.completion != nil ? request.url : nil
            if result == nil { try? FileManager.default.removeItem(at: request.url) }
            if let completion = request.completion { DispatchQueue.main.async { completion(result) } }
        }

        private func destroy() {
            #if os(macOS) || os(iOS)
            cacheNetworkMonitor?.cancel()
            cacheNetworkMonitor = nil
            #if os(iOS)
            cacheLifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
            cacheLifecycleObservers.removeAll()
            #endif
            #endif
            if let handle { GPMPVClearSecondaryASS(UnsafeMutableRawPointer(handle)) }
            configuration.stream?.cancel()
            timer?.cancel()
            timer = nil
            #if os(iOS) || os(tvOS) || os(macOS)
            configuration.pixelBufferOutput?.invalidate()
            pixelBufferRenderer?.shutdown()
            pixelBufferRenderer = nil
            #endif
            #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
            softwareRenderer.shutdown()
            #endif
            if let handle {
                self.handle = nil
                mpv_terminate_destroy(handle)
            }
            for url in cachedSubtitles { try? FileManager.default.removeItem(at: url) }
            cachedSubtitles.removeAll(); subtitleOrigins.removeAll()
            pendingSubtitles.removeAll()
            for id in Array(snapshots.keys) { finishSnapshot(id, success: false) }
            let releasedLayer = layer
            layer = nil
            DispatchQueue.main.async { _ = releasedLayer } // Final surface release on AppKit's thread.
        }

        private func fail(_ stage: Failure.Stage, code: Int32? = nil, option: String? = nil) {
            guard !closed, !failed else { return }
            failed = true
            let failure = Failure(stage: stage, code: code)
            // Only our stage/option name and libmpv's fixed error description.
            // Never log source URLs, option values, headers or raw decoder logs.
            let reason = code.map { String(cString: mpv_error_string($0)) } ?? "unavailable"
            NSLog("[MPV] failure stage=%@ option=%@ code=%@ reason=%@", stage.rawValue,
                  option ?? "-", code.map { String($0) } ?? "-", reason)
            destroy()
            DispatchQueue.main.async { [onError] in onError(failure) }
        }

        @discardableResult
        private func send(_ args: [String], fatal: Bool = false, requestID: UInt64 = 0) -> Bool {
            guard let handle else { return false }
            let strings = args.map { strdup($0) }
            defer { strings.forEach { free($0) } }
            var pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
            let status = mpv_command_async(handle, fatal ? 1 : requestID, &pointers)
            if status < 0 {
                if fatal { fail(.load, code: status) }
                return false
            }
            return true
        }

        private func string(_ property: String) -> String {
            guard let handle, let value = mpv_get_property_string(handle, property) else { return "" }
            defer { mpv_free(value) }
            return String(cString: value)
        }

        #if os(macOS) || os(iOS)
        private func configureDiskCache(_ handle: OpaquePointer) {
            guard !MPVPlaybackCachePolicy.options(enabled: configuration.readAheadCache, url: configuration.url).isEmpty else { return }
            state.diskCacheMode = .memory
            observeCachePolicy()
            _ = mpv_set_option_string(handle, "demuxer-readahead-secs", "0")
            guard let directory = MacMPVDiskCachePolicy.prepareDirectory() else { state.diskCacheReason = .directory; return }
            guard let free = MacMPVDiskCachePolicy.freeBytes(at: directory) else { state.diskCacheReason = .statistics; return }
            guard MacMPVDiskCachePolicy.canStart(freeBytes: free) else { state.diskCacheReason = .space; return }
            // Enable last, so an unsupported preliminary option cannot start disk writes.
            let options = [("demuxer-cache-dir", directory.path),
                           ("demuxer-cache-unlink-files", "immediate"),
                           ("demuxer-readahead-secs", "0"),
                           ("cache-secs", "120"), ("cache-on-disk", "yes")]
            for (name, value) in options {
                let result = mpv_set_option_string(handle, name, value)
                if result < 0 {
                    state.diskCacheReason = .option
                    NSLog("[MPV cache] rejected option=%@ code=%d", name, result)
                    _ = mpv_set_option_string(handle, "cache-on-disk", "no")
                    _ = mpv_set_option_string(handle, "cache-secs", "120")
                    return
                }
            }
            diskCacheDirectory = directory
            state.diskCacheMode = .disk
        }

        private func observeCachePolicy() {
            let monitor = NWPathMonitor()
            cacheNetworkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, !self.closed else { return }
                self.cacheNetworkAllowsReadAhead = MPVPlaybackCachePolicy.allowsExtendedReadAhead(
                    connected: path.status == .satisfied, expensive: path.isExpensive,
                    constrained: path.isConstrained,
                    wifiOrEthernet: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            }
            monitor.start(queue: queue)
            #if os(iOS)
            for (name, foreground) in [(UIApplication.didEnterBackgroundNotification, false),
                                       (UIApplication.willEnterForegroundNotification, true)] {
                cacheLifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.queue.async { [weak self] in self?.cacheForeground = foreground }
                })
            }
            DispatchQueue.main.async { [weak self] in
                let foreground = UIApplication.shared.applicationState != .background
                self?.queue.async { [weak self] in self?.cacheForeground = foreground }
            }
            #endif
        }

        /// Runs only on the existing engine queue, including while playback is paused.
        private func monitorDiskCache(_ handle: OpaquePointer) -> Bool {
            guard state.diskCacheMode != .inactive else { return true }
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= nextDiskCacheCheck else { return true }
            nextDiskCacheCheck = now + 1
            var foreground = true
            #if os(iOS)
            foreground = cacheForeground
            #endif
            let seconds = MPVPlaybackCachePolicy.readAheadSeconds(
                extended: cacheNetworkAllowsReadAhead && state.diskCacheMode == .disk, foreground: foreground, paused: flag("pause"))
            if seconds != cacheReadAheadSeconds {
                let result = mpv_set_property_string(handle, "cache-secs", seconds)
                guard result >= 0 else { fail(.playback, code: result, option: "cache-secs"); return false }
                cacheReadAheadSeconds = seconds
            }
            guard state.diskCacheMode == .disk, let directory = diskCacheDirectory else { return true }
            // Use the same native map snapshot as the seekable ranges, not a nested
            // property path whose availability/conversion differs between libmpv builds.
            if let bytes = diskFileBytes { state.diskCacheBytes = bytes }
            let free = MacMPVDiskCachePolicy.freeBytes(at: directory)
            let reason = diskCacheMonitor.fallbackReason(bytes: diskFileBytes, free: free, loaded: state.loaded)
            guard let reason else { return true }
            state.diskCacheReason = reason
            NSLog("[MPV cache] switching to memory reason=%@", reason.rawValue)
            // Turning off disk cache preserves old disk packets but sends new packets to RAM.
            // Never toggle back on: mpv would append to the same file again.
            let fallbackSeconds = MPVPlaybackCachePolicy.readAheadSeconds(
                extended: false, foreground: foreground, paused: flag("pause"))
            let restore = [("cache-on-disk", "no"), ("cache-secs", fallbackSeconds),
                           ("demuxer-max-bytes", "67108864"), ("demuxer-max-back-bytes", "33554432")]
            for (name, value) in restore {
                let result = mpv_set_property_string(handle, name, value)
                guard result >= 0 else { fail(.playback, code: result, option: name); return false }
            }
            state.diskCacheMode = .memory
            cacheReadAheadSeconds = fallbackSeconds
            return true
        }
        #endif

        private func cachedRanges() -> [MPVBufferedRange] {
            #if os(macOS) || os(iOS)
            diskFileBytes = nil
            #endif
            guard let handle else { return [] }
            var node = mpv_node()
            guard mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
            defer { mpv_free_node_contents(&node) }
            func member(_ node: mpv_node, _ key: String) -> mpv_node? {
                guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list,
                      let keys = list.pointee.keys, let values = list.pointee.values else { return nil }
                for index in 0..<Int(list.pointee.num) {
                    if let name = keys[index], String(cString: name) == key { return values[index] }
                }
                return nil
            }
            #if os(macOS) || os(iOS)
            if let bytes = member(node, "file-cache-bytes"), bytes.format == MPV_FORMAT_INT64, bytes.u.int64 >= 0 {
                diskFileBytes = bytes.u.int64
            }
            #endif
            guard let ranges = member(node, "seekable-ranges"), ranges.format == MPV_FORMAT_NODE_ARRAY,
                  let list = ranges.u.list, let values = list.pointee.values else { return [] }
            return (0..<Int(list.pointee.num)).compactMap { index in
                guard let start = member(values[index], "start"), start.format == MPV_FORMAT_DOUBLE,
                      let end = member(values[index], "end"), end.format == MPV_FORMAT_DOUBLE,
                      start.u.double_.isFinite, end.u.double_.isFinite, end.u.double_ > start.u.double_ else { return nil }
                return MPVBufferedRange(start: start.u.double_, end: end.u.double_)
            }
        }

        private func number(_ property: String) -> Double {
            guard let handle else { return 0 }
            var value: Double = 0
            guard mpv_get_property(handle, property, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
            return value
        }

        private func optionalNumber(_ property: String) -> Double? {
            guard let handle else { return nil }
            var value: Double = 0
            guard mpv_get_property(handle, property, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
            return value
        }

        private func flag(_ property: String) -> Bool {
            guard let handle else { return false }
            var value: Int32 = 0
            return mpv_get_property(handle, property, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
        }

        private func poll() {
            guard let handle, !closed, !failed else { return }
            while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
                switch event.pointee.event_id {
                case MPV_EVENT_FILE_LOADED:
                    state.loaded = true
                    tracksDirty = true
                    for url in configuration.subtitles {
                        _ = send(["sub-add", url.isFileURL ? url.path : url.absoluteString, "auto"])
                    }
                    for url in cachedSubtitles {
                        _ = send(["sub-add", url.path, "auto", subtitleOrigins[url.path]?.deletingPathExtension().lastPathComponent ?? ""])
                    }
                    for args in pendingSubtitles { _ = send(args) }
                    pendingSubtitles.removeAll()
                case MPV_EVENT_COMMAND_REPLY:
                    if event.pointee.reply_userdata == 1 && event.pointee.error < 0 {
                        fail(.load, code: event.pointee.error); return
                    }
                    if let data = event.pointee.data {
                        let reply = data.assumingMemoryBound(to: mpv_event_command.self).pointee
                        handleSnapshotReply(event.pointee.reply_userdata, error: event.pointee.error, result: reply.result)
                    }
                case MPV_EVENT_PROPERTY_CHANGE: tracksDirty = true
                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if end.reason == MPV_END_FILE_REASON_ERROR { fail(.playback, code: end.error); return }
                    }
                case MPV_EVENT_SHUTDOWN: fail(.shutdown); return
                default: break
                }
            }
            if tracksDirty {
                tracksDirty = false
                let count = min(max(Int(number("track-list/count")), 0), 512)
                state.tracks = (0..<count).compactMap { index in
                    let path = "track-list/\(index)"
                    guard let id = Int(string("\(path)/id")) else { return nil }
                    return Track(id: id, type: string("\(path)/type"), title: string("\(path)/title"),
                                 language: string("\(path)/lang"), codec: string("\(path)/codec"), external: flag("\(path)/external"),
                                 externalFilename: subtitleOrigins[string("\(path)/external-filename")]?.absoluteString ?? string("\(path)/external-filename"), sourceID: UInt64(string("\(path)/src-id")))
                }
            }
            #if os(iOS) || os(tvOS) || os(macOS)
            // Buffer growth is real input progress even before the playback clock starts.
            var bufferedBytes: Int64 = 0
            if mpv_get_property(handle, "demuxer-cache-state/fw-bytes", MPV_FORMAT_INT64, &bufferedBytes) >= 0 {
                state.bufferedBytes = max(0, bufferedBytes)
            }
            #endif
            state.time = number("time-pos")
            state.duration = number("duration")
            state.bufferedRanges = cachedRanges()
            #if os(macOS) || os(iOS) || os(tvOS)
            let cacheIsIdle = flag("demuxer-cache-idle")
            state.cacheReadIdle = cacheIsIdle
            state.cacheInputBytesPerSecond = cacheReadSpeedSmoother.update(
                idle: cacheIsIdle, now: ProcessInfo.processInfo.systemUptime) {
                    if let stream = configuration.stream {
                        return stream.inputBytesPerSecond()
                    }
                    var inputRate: Int64 = 0
                    return mpv_get_property(handle, "cache-speed", MPV_FORMAT_INT64, &inputRate) >= 0 && inputRate >= 0 ? inputRate : nil
                }
            #endif
            #if os(macOS) || os(iOS)
            guard monitorDiskCache(handle) else { return }
            #endif
            state.paused = flag("pause")
            state.buffering = !state.loaded || flag("paused-for-cache") || flag("seeking")
            state.ended = flag("eof-reached")
            state.seekable = flag("seekable")
            state.size = CGSize(width: number("video-out-params/dw"), height: number("video-out-params/dh"))
            state.videoTransfer = string("video-params/gamma")
            #if os(iOS) || os(tvOS) || os(macOS)
            if let renderer = pixelBufferRenderer, state.size.width > 1, state.size.height > 1 {
                renderer.confirmSourceTransfer(state.videoTransfer, primaries: string("video-params/primaries"))
                if !state.videoTransfer.isEmpty, state.videoTransfer != "auto",
                   !MPVPixelBufferColorPolicy.supports(transfer: state.videoTransfer) {
                    fail(.frameOutput); return
                }
                renderer.configure(sourceSize: state.size)
            }
            #endif
            state.audio = Int(string("aid")) ?? -1
            state.subtitle = Int(string("sid")) ?? -1
            state.secondary = Int(string("secondary-sid")) ?? -1
            state.secondaryText = string("secondary-sub-text")
            let geometry = GPMPVGetSecondaryASS(UnsafeMutableRawPointer(handle))
            state.secondaryASSBounds = geometry.hasBounds ? geometry.bounds : nil
            state.secondaryASSHasContent = geometry.hasContent
            #if os(iOS) || os(tvOS) || os(macOS)
            state.secondaryStart = optionalNumber("secondary-sub-start")
            state.secondaryEnd = optionalNumber("secondary-sub-end")
            #endif
            state.primaryText = string("sub-text")
            state.primaryStart = optionalNumber("sub-start")
            state.primaryEnd = optionalNumber("sub-end")
            let taggedTitle = string("metadata/by-key/title")
            state.metadata = ["artist": string("metadata/by-key/artist"),
                              "albumArtist": string("metadata/by-key/album_artist"),
                              "album": string("metadata/by-key/album"),
                              "author": string("metadata/by-key/author"),
                              "composer": string("metadata/by-key/composer"),
                              "title": taggedTitle.isEmpty ? (configuration.audioOnly ? "" : string("media-title")) : taggedTitle]
            // Only memory-backed properties; never open another decoder or read the media here.
            let diagnosticTime = ProcessInfo.processInfo.systemUptime
            if diagnosticTime - lastHDRInfoTime >= 1 {
                lastHDRInfoTime = diagnosticTime
                state.hdrInfo = configuration.audioOnly ? MPVHDRInfo() : MPVHDRInfo(read: string)
                if state.hdrInfo.isHDR, let videoID = Int(string("vid")) {
                    state.hdrInfo.codec = state.tracks.first { $0.type == "video" && $0.id == videoID }?.codec ?? ""
                }
                if usesPixelBufferOutput, state.hdrInfo.isHDR {
                    // This renderer explicitly converts its auxiliary frames to SDR BGRA.
                    state.hdrInfo.targetTransfer = "srgb"
                    state.hdrInfo.targetPrimaries = "bt.709"
                }
            }
            let snapshot = state
            let displayLayer = usesPixelBufferOutput ? nil : layer
            DispatchQueue.main.async { [onState] in
                var snapshot = snapshot
                if snapshot.hdrInfo.isHDR, let displayLayer {
                    snapshot.hdrInfo.layerColorSpace = displayLayer.colorspace?.name.map { $0 as String } ?? ""
                    snapshot.hdrInfo.layerPixelFormat = String(describing: displayLayer.pixelFormat)
                    #if os(macOS)
                    snapshot.hdrInfo.layerEDRRequested = displayLayer.wantsExtendedDynamicRangeContent
                    #elseif os(iOS)
                    if #available(iOS 16.0, *) {
                        snapshot.hdrInfo.layerEDRRequested = displayLayer.wantsExtendedDynamicRangeContent
                    }
                    #endif
                }
                onState(snapshot)
            }
        }
    }
}

#if os(macOS)
typealias MacMPVEngine = MPVPlaybackEngine

/// EDR changes are scheduled on AppKit's thread. Never block the renderer waiting
/// for the main thread: a window can be closing while libmpv is being destroyed.
fileprivate final class MacMPVMetalLayer: GPMPVMetalLayer {
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.async { [weak self] in self?.wantsExtendedDynamicRangeContent = newValue } }
        }
    }

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue } }
    }
}

struct MacMPVVideoView: NSViewRepresentable {
    let engine: MacMPVEngine
    let fillScreen: Bool

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {
        let view = host.surface
        engine.videoView = view
        view.connect(engine)
        if view.lastFillScreen != fillScreen {
            view.lastFillScreen = fillScreen
            engine.set("panscan", fillScreen ? "1" : "0")
        }
    }

    final class Host: NSView {
        let surface = Surface()
        override init(frame: NSRect) {
            super.init(frame: frame)
            surface.frame = bounds
            surface.autoresizingMask = [.width, .height]
            addSubview(surface)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    final class Surface: NSView {
        fileprivate let metal = MacMPVMetalLayer()
        fileprivate var lastFillScreen: Bool?
        private weak var engine: MacMPVEngine?
        private var renderingStarted = false
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            metal.device = MTLCreateSystemDefaultDevice()
            metal.backgroundColor = NSColor.black.cgColor
            wantsLayer = true
            // AppKit manages the backing layer; MoltenVK owns the drawable layer.
            // Do not let view backing updates resize an active swapchain's textures.
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            layer?.addSublayer(metal)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() { super.layout(); updateGeometry() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGeometry() }
        fileprivate func connect(_ engine: MacMPVEngine) {
            self.engine = engine
            updateGeometry()
        }
        fileprivate func updateGeometry() {
            guard let window, bounds.width > 1, bounds.height > 1 else { return }
            let scale = window.backingScaleFactor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metal.contentsScale = scale
            metal.frame = bounds
            CATransaction.commit()
            // Publish geometry and wake the VO thread; it resizes the swapchain,
            // video viewport and subtitles together between frames (also paused).
            metal.targetPixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            guard !renderingStarted, let engine else { return }
            // Only seed before mpv starts. Live drawableSize belongs to MoltenVK;
            // changing it on the UI thread can invalidate an in-flight render pass.
            metal.drawableSize = metal.targetPixelSize
            renderingStarted = true
            engine.attach(to: metal)
        }
    }
}
#endif
#endif
