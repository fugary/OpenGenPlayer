import Foundation
import AVFoundation

enum MacAudioSubtitleError: Error { case unreadable }

@main enum AudioReaderChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("output.wav")
        if !PlaybackEngineAvailability.current.mpv {
            do {
                _ = try await MPVAudioFileReader.inspect(input)
                preconditionFailure("Disabled mpv inspected media")
            } catch MPVAudioFileReader.Failure.disabled { }
            let blockedOutput = directory.appendingPathComponent("disabled-output.wav")
            do {
                try await MPVAudioFileReader.decode(input, trackID: 1, to: blockedOutput)
                preconditionFailure("Disabled mpv decoded media")
            } catch MPVAudioFileReader.Failure.disabled { }
            precondition(!FileManager.default.fileExists(atPath: blockedOutput.path))
            print("PASS: production audio inspection and PCM decode reject disabled mpv")
            return
        }
        FileHandle.standardError.write(Data("Checking metadata\n".utf8))
        let metadata = try await MPVAudioFileReader.inspect(input)
        precondition(abs(metadata.duration - 2) < 0.05 && metadata.tracks.count == 1)
        precondition(metadata.tracks[0].ordinal == 1 && metadata.tracks[0].id > 0)
        FileHandle.standardError.write(Data("Checking PCM decode\n".utf8))
        try await MPVAudioFileReader.decode(input, trackID: metadata.tracks[0].id, to: output)
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let decodedDuration = try await asset.load(.duration).seconds
        precondition(audioTracks.count == 1 && abs(decodedDuration - 2) < 0.05)
        let existing = try Data(contentsOf: output)
        do {
            try await MPVAudioFileReader.decode(input, trackID: metadata.tracks[0].id, to: output)
            preconditionFailure("Must not overwrite output")
        } catch MPVAudioFileReader.Failure.invalidInput { }
        let preserved = try Data(contentsOf: output)
        precondition(preserved == existing)
        let invalid = directory.appendingPathComponent("invalid.wav")
        do {
            try await MPVAudioFileReader.decode(input, trackID: 999, to: invalid)
            preconditionFailure("Must not decode a different track")
        } catch { }
        precondition(!FileManager.default.fileExists(atPath: invalid.path))
        let cancelled = directory.appendingPathComponent("cancelled.wav")
        let task = Task { try await MPVAudioFileReader.decode(input, trackID: metadata.tracks[0].id, to: cancelled) }
        task.cancel()
        do { try await task.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancelled.path))
        let multi = directory.appendingPathComponent("multi.mkv")
        let origins = try MacMatroskaAudioOrigin.origins(url: multi)
        precondition(origins == [1, 1.5])
        let multiMetadata = try await MPVAudioFileReader.inspect(multi)
        precondition(multiMetadata.tracks.count == 2)
        precondition(multiMetadata.tracks.map(\.ordinal) == [1, 2])
        precondition(multiMetadata.tracks.map(\.language) == ["eng", "jpn"])
        for (index, track) in multiMetadata.tracks.enumerated() {
            try await MPVAudioFileReader.decode(multi, trackID: track.id,
                to: directory.appendingPathComponent("track-\(index).wav"))
        }
        print("PASS: real libmpv metadata, PCM output, track rejection, output protection and cancellation")
    }
}
