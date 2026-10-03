import Foundation
import zlib

public enum GzipDecompressor {
    
    /// Checks whether the provided data has the GZIP file format magic header (0x1F, 0x8B).
    public static func isGzipped(data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0x1f && data[1] == 0x8b
    }
    
    /// Decompresses GZIP or Deflate data into uncompressed Data.
    /// If data is not gzipped and isGzipped check is false, returns the original data.
    public static func decompress(data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        
        // If not gzipped, return as is
        guard isGzipped(data: data) else {
            return data
        }
        
        var stream = z_stream()
        var status: Int32
        
        // 15 + 32 enables automatic zlib and gzip header decoding
        status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError.initFailed(status)
        }
        
        defer {
            inflateEnd(&stream)
        }
        
        let chunkSize = 64 * 1024 // 64 KB chunk
        var decompressed = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            buffer.deallocate()
        }
        
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunkSize)
                
                status = inflate(&stream, Z_NO_FLUSH)
                
                if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                    throw GzipError.inflateFailed(status)
                }
                
                let count = chunkSize - Int(stream.avail_out)
                if count > 0 {
                    decompressed.append(buffer, count: count)
                }
            } while status == Z_OK
        }
        
        guard status == Z_STREAM_END || status == Z_OK else {
            throw GzipError.inflateFailed(status)
        }
        
        return decompressed
    }
    
    public enum GzipError: LocalizedError {
        case initFailed(Int32)
        case inflateFailed(Int32)
        
        public var errorDescription: String? {
            switch self {
            case .initFailed(let code):
                return "Failed to initialize zlib stream (code \(code))"
            case .inflateFailed(let code):
                return "Failed to decompress gzip stream (code \(code))"
            }
        }
    }
}
