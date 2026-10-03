#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import Darwin
import Libavformat
import Libavutil

/// Reads audio tags and embedded cover bytes without a playback engine or audio decoder.
/// Network authentication and file-version checks remain owned by the supplied range reader.
public enum EmbeddedAudioArtworkReader {
    public struct Metadata: Sendable {
        public let tags: [String: String]
        public let artwork: Data?
        /// False when IO budgets, cancellation or a malformed tag prevented a complete read.
        public let isComplete: Bool
    }

    private final class Input {
        let file: FileHandle?
        let remote: RangeInput?
        let size: UInt64
        let deadline: TimeInterval
        var offset: UInt64 = 0
        var remaining = 16 * 1024 * 1024
        var seeks = 128
        var incomplete = false
        init(url: URL) throws {
            let handle = try FileHandle(forReadingFrom: url)
            file = handle; remote = nil
            size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            deadline = ProcessInfo.processInfo.systemUptime + 3
        }
        init(size: UInt64, remote: RangeInput) {
            file = nil; self.remote = remote; self.size = size
            deadline = ProcessInfo.processInfo.systemUptime + 10
        }
        func read(count: Int) throws -> Data {
            let data: Data
            if let file { data = try file.read(upToCount: count) ?? Data() }
            else if let remote { data = try remote.read(offset: offset, count: count, size: size) }
            else { return Data() }
            offset += UInt64(data.count)
            return data
        }
        func seek(_ target: UInt64) throws {
            try file?.seek(toOffset: target)
            offset = target
        }
        deinit { try? file?.close() }
        var interrupted: Bool { Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
    }

    /// One demux worker owns cache/budgets. Cancellation only accesses the locked waiter.
    private final class RangeInput: @unchecked Sendable {
        private final class Pending {
            let condition = NSCondition()
            var result: Result<Data, Error>?
            func finish(_ value: Result<Data, Error>) {
                condition.lock(); defer { condition.unlock() }
                guard result == nil else { return }
                result = value; condition.broadcast()
            }
            func wait(until deadline: Date) throws -> Data {
                condition.lock(); defer { condition.unlock() }
                while result == nil {
                    if !condition.wait(until: deadline) { throw URLError(.timedOut) }
                }
                return try result!.get()
            }
        }
        let reader: @Sendable (UInt64, Int) async throws -> Data
        let deadline = Date().addingTimeInterval(10)
        let lock = NSLock()
        var cancelled = false
        var cancelPending: (() -> Void)?
        var remaining = 8 * 1024 * 1024
        var requests = 64
        var cache = Data()
        var cacheOffset: UInt64 = 0
        init(reader: @escaping @Sendable (UInt64, Int) async throws -> Data) { self.reader = reader }
        func cancel() {
            lock.lock(); cancelled = true; let stop = cancelPending; lock.unlock()
            stop?()
        }
        func read(offset: UInt64, count: Int, size: UInt64) throws -> Data {
            try Task.checkCancellation()
            guard offset < size else { return Data() }
            if cache.isEmpty || offset < cacheOffset || offset - cacheOffset >= UInt64(cache.count) {
                guard requests > 0, remaining > 0, Date() < deadline else { throw URLError(.resourceUnavailable) }
                let amount = min(256 * 1024, remaining, Int(min(size - offset, UInt64(Int.max))))
                remaining -= amount; requests -= 1
                let pending = Pending()
                lock.lock()
                guard !cancelled else { lock.unlock(); throw CancellationError() }
                let task = Task.detached { [reader] in
                    do { pending.finish(.success(try await reader(offset, amount))) }
                    catch { pending.finish(.failure(error)) }
                }
                cancelPending = { task.cancel(); pending.finish(.failure(CancellationError())) }
                lock.unlock()
                defer { task.cancel(); lock.lock(); cancelPending = nil; lock.unlock() }
                let data = try pending.wait(until: deadline)
                try Task.checkCancellation()
                guard data.count == amount else { throw URLError(.badServerResponse) }
                cache = data; cacheOffset = offset
            }
            let start = Int(offset - cacheOffset)
            return cache.subdata(in: start..<min(cache.count, start + count))
        }
    }

    /// Supply an independent, version-checked reader. At most 8 MiB/64 requests are fetched.
    public static func read(size: UInt64, range: @escaping @Sendable (UInt64, Int) async throws -> Data) async throws -> Data? {
        try await readMetadata(size: size, range: range)?.artwork
    }

    public static func readMetadata(size: UInt64, range: @escaping @Sendable (UInt64, Int) async throws -> Data) async throws -> Metadata? {
        guard size > 0, size <= UInt64(Int64.max) else { return nil }
        let remote = RangeInput(reader: range)
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try parse(Input(size: size, remote: remote))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); remote.cancel()
        }
    }

    public static func read(_ url: URL) async throws -> Data? {
        try await readMetadata(url)?.artwork
    }

    public static func readMetadata(_ url: URL) async throws -> Metadata? {
        let task = Task.detached(priority: .utility) { try readFile(url) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func readFile(_ url: URL) throws -> Metadata? {
        try Task.checkCancellation()
        guard url.isFileURL else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try parse(Input(url: url))
    }

    private static func parse(_ input: Input) throws -> Metadata? {
        defer { withExtendedLifetime(input) {} }
        guard let buffer = av_malloc(32 * 1024)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var io = avio_alloc_context(buffer, 32 * 1024, 0, Unmanaged.passUnretained(input).toOpaque(), { opaque, buffer, count in
            guard let opaque, let buffer, count > 0 else { return -1 }
            let input = Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
            guard !input.interrupted, input.remaining > 0 else { input.incomplete = true; return -1 }
            do {
                let bytes = try input.read(count: min(Int(count), input.remaining))
                guard !bytes.isEmpty else { return -541478725 } // AVERROR_EOF
                input.remaining -= bytes.count
                bytes.copyBytes(to: buffer, count: bytes.count)
                return Int32(bytes.count)
            } catch { input.incomplete = true; return -1 }
        }, nil, { opaque, offset, whence in
            guard let opaque else { return -1 }
            let input = Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
            guard !input.interrupted else { return -1 }
            if whence == AVSEEK_SIZE { return Int64(clamping: input.size) }
            guard input.seeks > 0 else { input.incomplete = true; return -1 }
            input.seeks -= 1
            do {
                let base: Int64
                switch whence & ~AVSEEK_FORCE {
                case 0: base = 0
                case 1: base = Int64(clamping: input.offset)
                case 2: base = Int64(clamping: input.size)
                default: return -1
                }
                let (target, overflow) = base.addingReportingOverflow(offset)
                guard !overflow, target >= 0, UInt64(target) <= input.size else { return -1 }
                try input.seek(UInt64(target))
                return target
            } catch { input.incomplete = true; return -1 }
        })
        guard io != nil else { av_free(buffer); return nil }
        defer {
            // libavformat can replace the AVIO buffer while probing.
            av_free(io?.pointee.buffer)
            io?.pointee.buffer = nil
            avio_context_free(&io)
        }
        var format = avformat_alloc_context()
        guard format != nil else { return nil }
        defer { avformat_close_input(&format) }
        format?.pointee.pb = io
        format?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        format?.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque else { return 1 }
            return Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().interrupted ? 1 : 0
        }, opaque: Unmanaged.passUnretained(input).toOpaque())
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        // Only self-contained audio containers: never follow playlists or external URLs.
        av_dict_set(&options, "format_whitelist", "mp3,flac,mov,ogg,ape,wav,wv,aiff,matroska,webm", 0)
        av_dict_set(&options, "protocol_whitelist", "", 0)
        av_dict_set(&options, "probesize", "1048576", 0)
        guard avformat_open_input(&format, nil, nil, &options) >= 0, let format else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard !input.interrupted, format.pointee.nb_streams <= 1024 else { return nil }
        var tags: [String: String] = [:]
        var dictionaries = [format.pointee.metadata]
        let audioStreams = (0..<Int(format.pointee.nb_streams)).compactMap { format.pointee.streams[$0] }
            .filter { $0.pointee.codecpar?.pointee.codec_type == AVMEDIA_TYPE_AUDIO }
        // Vorbis/Opus tags live on the stream. Do not guess between multiple audio tracks.
        if audioStreams.count == 1 { dictionaries.append(audioStreams[0].pointee.metadata) }
        var entries = 0
        for dictionary in dictionaries {
            var entry: UnsafeMutablePointer<AVDictionaryEntry>?
            while let next = av_dict_get(dictionary, "", entry, AV_DICT_IGNORE_SUFFIX) {
                entry = next
                entries += 1
                guard entries <= 1024 else { input.incomplete = true; break }
                guard let key = next.pointee.key, strnlen(key, 128) < 128,
                      let value = next.pointee.value, strnlen(value, 16 * 1024) < 16 * 1024 else {
                    input.incomplete = true; continue
                }
                let canonical: String
                switch String(cString: key).lowercased().filter({ $0.isLetter || $0.isNumber }) {
                case "title": canonical = "title"
                case "artist": canonical = "artist"
                case "album": canonical = "album"
                case "albumartist": canonical = "albumArtist"
                case "author": canonical = "author"
                case "composer": canonical = "composer"
                default: continue
                }
                let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, tags[canonical] == nil { tags[canonical] = text }
            }
        }
        var artwork: Data?
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[index],
                  stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 else { continue }
            let packet = stream.pointee.attached_pic
            guard packet.size > 0, packet.size <= 8 * 1024 * 1024, let data = packet.data else {
                input.incomplete = true; continue
            }
            artwork = Data(bytes: data, count: Int(packet.size))
            break
        }
        try Task.checkCancellation()
        return Metadata(tags: tags, artwork: artwork, isComplete: !input.incomplete && !input.interrupted)
    }
}
#endif
