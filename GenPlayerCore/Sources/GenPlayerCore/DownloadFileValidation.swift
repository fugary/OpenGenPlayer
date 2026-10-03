import Foundation

/// Validation for complete download artifacts, before they enter offline storage.
public enum DownloadFileValidation {
    // The platform shell supplies its resource bundle and selected app language.
    public static var localize: (String) -> String = { NSLocalizedString($0, comment: "") }

    public enum Failure: Error, LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case incompleteFile

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return localize("The server did not return a downloadable file. Please retry.")
            case .httpStatus(let status):
                return String(format: localize("Download failed (HTTP %d). Please retry."), status)
            case .incompleteFile:
                return localize("The downloaded file is incomplete or has changed. Please download it again.")
            }
        }
    }

    @discardableResult
    public static func validateHTTP(response: URLResponse?, fileURL: URL) throws -> Int64 {
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
        guard response.statusCode != 204, response.statusCode != 205 else { throw Failure.invalidResponse }

        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasEncodedBody = !encoding.isEmpty && encoding != "identity"
        let expectedBytes: Int64?
        if response.statusCode == 206 {
            // URLSession's resumed artifact includes the previously downloaded prefix.
            // Content-Length describes only this response's suffix, not the final file.
            guard let value = response.value(forHTTPHeaderField: "Content-Range"),
                  let total = completeRangeLength(value), !hasEncodedBody else {
                throw Failure.invalidResponse
            }
            expectedBytes = total
        } else {
            // URLSession may transparently decode an encoded body. Its wire length is
            // not a reliable on-disk size; unknown/chunked lengths are also left alone.
            expectedBytes = !hasEncodedBody && response.expectedContentLength >= 0
                ? response.expectedContentLength : nil
        }
        return try validateFile(at: fileURL, expectedBytes: expectedBytes)
    }

    @discardableResult
    public static func validateFile(at url: URL, expectedBytes: Int64? = nil) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw Failure.incompleteFile }
        let actualBytes = Int64(size)
        if let expectedBytes, expectedBytes >= 0, actualBytes != expectedBytes {
            throw Failure.incompleteFile
        }
        return actualBytes
    }

    private static func completeRangeLength(_ value: String) -> Int64? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]), total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, start <= end, end == total - 1 else { return nil }
        return total
    }
}
