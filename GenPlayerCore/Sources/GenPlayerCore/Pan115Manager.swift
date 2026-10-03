import Foundation
import Security

// MARK: - 115 Chrome Extension Direct Downloader (1:1 Aligned with AList/SheltonZhu/115driver)
//
// Reference:
//   https://github.com/SheltonZhu/115driver/tree/main/pkg/crypto/m115
//   https://github.com/SheltonZhu/115driver/blob/main/pkg/driver/download.go
//
// Protocol summary:
//   1. GenerateKey() → 16-byte random key
//   2. Encode(json, key): XOR(key,4) → reverse → XOR(clientKey) → prepend key → RSA-PKCS1 → base64
//   3. POST https://proapi.115.com/app/chrome/downurl?t=<unix>  data=<base64>
//   4. Response["data"] = base64(rsaEncrypted(key16 || XOR-payload))
//   5. Decode: base64 → rsaDecrypt(same N,E) → strip PKCS1 padding → XOR(embeddedKey,12) → reverse → XOR(origKey,4)
//
// IMPORTANT: The returned f=1 CDN URL has full signature (k=..., t=..., u=...) and works directly in VLC/AVPlayer without proxy.

public enum Pan115ChromeDownloader {

    // MARK: - XOR Constants (from xor.go)

    private static let xorKeySeed: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]

    private static let xorClientKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
        0x4c, 0x01, 0x3f, 0x46,
    ]

    // MARK: - RSA Modulus N (1024-bit, 128 bytes)
    // From rsa.go — same N and E=0x10001 used for BOTH encrypt AND decrypt

    private static let rsaN: [UInt8] = {
        let hex = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
            i = j
        }
        return bytes
    }()

    // MARK: - BigInteger modular exponentiation (for rsaDecrypt)
    // Computes base^exp mod modulus using fast bit-level binary long division.

    private static func bigModPow(base: [UInt8], exp: [UInt8], mod: [UInt8]) -> [UInt8] {
        var result = bigFromInt(1, size: mod.count)
        let b = bigModFast(base, mod)
        var started = false
        for byte in exp {
            for bitIdx in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> bitIdx) & 1
                if !started {
                    if bit == 1 {
                        started = true
                        result = b
                    }
                } else {
                    result = bigModFast(bigMul(result, result, size: mod.count * 2), mod)
                    if bit == 1 {
                        result = bigModFast(bigMul(result, b, size: mod.count * 2), mod)
                    }
                }
            }
        }
        return result
    }

    private static func bigFromInt(_ value: Int, size: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: size)
        var v = value
        var i = size - 1
        while v > 0 && i >= 0 {
            result[i] = UInt8(v & 0xFF)
            v >>= 8
            i -= 1
        }
        return result
    }

    private static func bigMul(_ a: [UInt8], _ b: [UInt8], size: Int) -> [UInt8] {
        var result = [UInt32](repeating: 0, count: a.count + b.count)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                let prod = UInt32(a[i]) * UInt32(b[j])
                let pos = i + j + 1
                let sum = result[pos] + prod
                result[pos] = sum & 0xFFFF_FFFF
                var carry = sum >> 32
                var k = pos - 1
                while carry > 0 && k >= 0 {
                    let s = result[k] + carry
                    result[k] = s & 0xFFFF_FFFF
                    carry = s >> 32
                    k -= 1
                }
            }
        }
        var bytes = [UInt8]()
        for r in result {
            bytes.append(contentsOf: [UInt8(r >> 24), UInt8((r >> 16) & 0xFF), UInt8((r >> 8) & 0xFF), UInt8(r & 0xFF)])
        }
        let totalBytes = bytes.count
        if totalBytes >= size {
            return Array(bytes[(totalBytes - size)...])
        }
        return [UInt8](repeating: 0, count: size - totalBytes) + bytes
    }

    private static func bigModFast(_ a: [UInt8], _ m: [UInt8]) -> [UInt8] {
        guard !bigIsZero(m) else { return a }
        var r = [UInt8]()
        for byte in a {
            for bitIdx in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> bitIdx) & 1
                var carry: UInt8 = bit
                for i in stride(from: r.count - 1, through: 0, by: -1) {
                    let nextCarry = r[i] >> 7
                    r[i] = (r[i] << 1) | carry
                    carry = nextCarry
                }
                if carry > 0 {
                    r.insert(carry, at: 0)
                }
                if bigCmp(r, m) >= 0 {
                    r = bigSub(r, m)
                    let firstNonZero = r.firstIndex(where: { $0 != 0 }) ?? r.count
                    r = Array(r[firstNonZero...])
                }
            }
        }
        if r.count < m.count {
            return [UInt8](repeating: 0, count: m.count - r.count) + r
        }
        return r
    }

    private static func bigIsZero(_ a: [UInt8]) -> Bool { a.allSatisfy { $0 == 0 } }

    private static func bigCmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let aStripped = a.drop(while: { $0 == 0 })
        let bStripped = b.drop(while: { $0 == 0 })
        if aStripped.count != bStripped.count { return aStripped.count < bStripped.count ? -1 : 1 }
        for (x, y) in zip(aStripped, bStripped) {
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
    }

    private static func bigSub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: max(a.count, b.count))
        let aOff = result.count - a.count
        let bOff = result.count - b.count
        for i in 0..<a.count { result[aOff + i] = a[i] }
        var borrow: Int = 0
        for i in stride(from: result.count - 1, through: 0, by: -1) {
            let bVal = i >= bOff ? Int(b[i - bOff]) : 0
            var diff = Int(result[i]) - bVal - borrow
            if diff < 0 { diff += 256; borrow = 1 } else { borrow = 0 }
            result[i] = UInt8(diff)
        }
        return result
    }

    // MARK: - RSA Encrypt & Decrypt

    private static let rsaPublicKey: SecKey? = {
        var der = Data([0x30, 0x81, 0x89, 0x02, 0x81, 0x81, 0x00])
        der.append(contentsOf: rsaN)
        der.append(contentsOf: [0x02, 0x03, 0x01, 0x00, 0x01])
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        var err: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
        if key == nil {
            print("[Pan115ChromeDownloader] RSA public key init failed: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return key
    }()

    private static func rsaEncrypt(_ input: [UInt8]) -> [UInt8]? {
        guard let key = rsaPublicKey else { return nil }
        let chunkSize = 117
        var result = [UInt8]()
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkSize, input.count)
            let chunk = Data(input[offset..<end])
            var cfErr: Unmanaged<CFError>?
            guard let encChunk = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, chunk as CFData, &cfErr) else {
                print("[Pan115ChromeDownloader] RSA encrypt slice failed: \(cfErr?.takeRetainedValue().localizedDescription ?? "unknown")")
                return nil
            }
            result.append(contentsOf: (encChunk as Data))
            offset += chunkSize
        }
        return result
    }

    private static func rsaDecrypt(_ input: [UInt8]) -> [UInt8] {
        let keyLength = 128
        let eBytes: [UInt8] = [0x01, 0x00, 0x01] // 65537
        var result = [UInt8]()
        var offset = 0
        while offset < input.count {
            let end = min(offset + keyLength, input.count)
            let slice = Array(input[offset..<end])
            let padded = slice.count < keyLength ? [UInt8](repeating: 0, count: keyLength - slice.count) + slice : slice
            let decrypted = bigModPow(base: padded, exp: eBytes, mod: rsaN)
            var found = false
            for i in 1..<decrypted.count {
                if decrypted[i] == 0 && i != 0 {
                    result.append(contentsOf: decrypted[(i+1)...])
                    found = true
                    break
                }
            }
            if !found && !decrypted.isEmpty {
                result.append(contentsOf: decrypted)
            }
            offset += keyLength
        }
        return result
    }

    // MARK: - XOR Primitives

    private static func xorDeriveKey(seed: [UInt8], size: Int) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            key[i] = (seed[i] &+ xorKeySeed[size * i]) & 0xff
            key[i] ^= xorKeySeed[size * (size - i - 1)]
        }
        return key
    }

    private static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        let dataSize = data.count
        let keySize = key.count
        guard keySize > 0 else { return }
        let mod = dataSize % 4
        if mod > 0 {
            for i in 0..<mod { data[i] ^= key[i % keySize] }
        }
        for i in mod..<dataSize { data[i] ^= key[(i - mod) % keySize] }
    }

    // MARK: - Encode / Decode (mirrors public.go)

    private static func encode(payload: [UInt8], key: [UInt8]) -> String? {
        var data = payload
        let k4 = xorDeriveKey(seed: key, size: 4)
        xorTransform(&data, key: k4)
        data.reverse()
        xorTransform(&data, key: xorClientKey)
        var buf = key
        buf.append(contentsOf: data)
        guard let encrypted = rsaEncrypt(buf) else { return nil }
        return Data(encrypted).base64EncodedString()
    }

    private static func decode(encoded: String, key: [UInt8]) -> [UInt8]? {
        guard let raw = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            print("[Pan115ChromeDownloader] Decode: base64 failed")
            return nil
        }
        let decrypted = rsaDecrypt([UInt8](raw))
        guard decrypted.count > 16 else {
            print("[Pan115ChromeDownloader] Decode: rsaDecrypt result too short (\(decrypted.count) bytes)")
            return nil
        }
        let embeddedKey = Array(decrypted[0..<16])
        var payload = Array(decrypted[16...])
        let k12 = xorDeriveKey(seed: embeddedKey, size: 12)
        xorTransform(&payload, key: k12)
        payload.reverse()
        let k4 = xorDeriveKey(seed: key, size: 4)
        xorTransform(&payload, key: k4)
        return payload
    }

    // MARK: - Public Fetch Direct Download URL

    public static func fetchDownloadURL(pickcode: String, cookie: String, logURL: Bool = true) async -> URL? {
        var key = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &key)

        let payloadStr = "{\"pickcode\":\"\(pickcode)\"}"
        guard let payloadBytes = payloadStr.data(using: .utf8).map({ [UInt8]($0) }) else { return nil }

        guard let encodedData = encode(payload: payloadBytes, key: key) else {
            print("[Pan115ChromeDownloader] Encode failed")
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://proapi.115.com/app/chrome/downurl?t=\(timestamp)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.61 Safari/537.36 115Browser/23.9.3.2", forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        guard let urlEncoded = encodedData.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        request.httpBody = "data=\(urlEncoded)".data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard (200...299).contains(http.statusCode) else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            if let encStr = json["data"] as? String, !encStr.isEmpty {
                if let decrypted = decode(encoded: encStr, key: key),
                   let decStr = String(bytes: decrypted, encoding: .utf8) {
                    if let decData = decStr.data(using: .utf8),
                       let decJson = try? JSONSerialization.jsonObject(with: decData) as? [String: Any] {
                        for (_, value) in decJson {
                            if let info = value as? [String: Any],
                               let urlStr = (info["url"] as? String) ?? (info["url"] as? [String: Any])?["url"] as? String,
                               !urlStr.isEmpty,
                               let directURL = URL(string: urlStr) {
                                if logURL { print("[Pan115ChromeDownloader] Resolved direct URL: \(directURL.absoluteString.prefix(120))...") }
                                return directURL
                            }
                        }
                    }
                }
            }

            if let dataDict = json["data"] as? [String: Any] {
                for (_, value) in dataDict {
                    if let info = value as? [String: Any],
                       let urlStr = (info["url"] as? String) ?? (info["url"] as? [String: Any])?["url"] as? String,
                       !urlStr.isEmpty,
                       let directURL = URL(string: urlStr) {
                        return directURL
                    }
                }
            }
        } catch {
            print("[Pan115ChromeDownloader] Request error: \(error.localizedDescription)")
        }
        return nil
    }
}

// MARK: - Pan115Manager Singleton

public final class Pan115Manager {
    public static let shared = Pan115Manager()
    public static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.61 Safari/537.36 115Browser/23.9.3.2"

    private let pathMappingLock = NSLock()
    private var pathIdMap: [String: String] = [:]
    private var pathPickCodeMap: [String: String] = [:]

    private init() {}

    // MARK: - Cache Helpers

    private func cacheKey(serverId: UUID, path: String) -> String {
        "\(serverId.uuidString):\(normalizePath(path))"
    }

    public func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") { p = "/" + p }
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public func fileId(forPath path: String, serverId: UUID) -> String? {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        return pathIdMap[cacheKey(serverId: serverId, path: path)]
    }

    public func setFileId(_ id: String, forPath path: String, serverId: UUID) {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        pathIdMap[cacheKey(serverId: serverId, path: path)] = id
    }

    public func pickcode(forPath path: String, serverId: UUID) -> String? {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        return pathPickCodeMap[cacheKey(serverId: serverId, path: path)]
    }

    public func setPickcode(_ pickcode: String, forPath path: String, serverId: UUID) {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        pathPickCodeMap[cacheKey(serverId: serverId, path: path)] = pickcode
    }

    // MARK: - Login Check

    public func checkLogin(cookie: String) async throws -> Bool {
        guard let url = URL(string: "https://webapi.115.com/files?aid=1&cid=0&limit=1") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://115.com", forHTTPHeaderField: "Referer")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let state = json["state"] as? Bool {
                return state
            }
            if let state = json["state"] as? Int {
                return state == 1
            }
        }
        return false
    }

    // MARK: - QR Code Login Session

    public struct QRCodeSessionInfo {
        public let uid: String
        public let qrCodeURL: URL
        public let time: Int64
        public let sign: String
    }

    public func startQRCodeLogin() async throws -> QRCodeSessionInfo {
        guard let url = URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token") else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get QR code token"])
        }

        let stateInt = (json["state"] as? NSNumber)?.intValue ?? (json["state"] as? Bool == true ? 1 : 0)
        guard stateInt == 1,
              let dataObj = json["data"] as? [String: Any],
              let uid = dataObj["uid"] as? String,
              let sign = dataObj["sign"] as? String else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse QR code token payload"])
        }

        let time = (dataObj["time"] as? NSNumber)?.int64Value ?? Int64(dataObj["time"] as? Int ?? 0)
        let qrURL = URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?uid=\(uid)")!
        return QRCodeSessionInfo(uid: uid, qrCodeURL: qrURL, time: time, sign: sign)
    }

    public func fetchQRCode() async throws -> QRCodeSessionInfo {
        try await startQRCodeLogin()
    }

    public enum QRCodeStatus {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
        case error(String)
    }

    public func pollQRCodeStatus(session: QRCodeSessionInfo) async -> QRCodeStatus {
        await pollQRCodeStatus(uid: session.uid, time: session.time, sign: session.sign)
    }

    public func pollQRCodeStatus(uid: String, time: Int64, sign: String) async -> QRCodeStatus {
        guard let url = URL(string: "https://qrcodeapi.115.com/get/status/?uid=\(uid)&time=\(time)&sign=\(sign)&_=\(Int(Date().timeIntervalSince1970 * 1000))") else {
            return .error("Invalid status URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .waiting
            }
            
            let stateInt = (json["state"] as? NSNumber)?.intValue ?? (json["state"] as? Bool == true ? 1 : 0)
            if stateInt == 0 {
                let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
                if msg.contains("过期") || msg.contains("expire") || msg.contains("失效") {
                    return .expired
                }
                return .waiting
            }
            
            if stateInt == 1, let dataObj = json["data"] as? [String: Any] {
                let statusInt = (dataObj["status"] as? NSNumber)?.intValue ?? (dataObj["status"] as? String).flatMap(Int.init) ?? -999
                
                if statusInt == 0 {
                    return .waiting
                } else if statusInt == 1 {
                    return .scanned
                } else if statusInt == 2 {
                    do {
                        let cookie = try await postQRCodeResult(uid: uid, app: "web")
                        return .success(cookie: cookie)
                    } catch {
                        if let macCookie = try? await postQRCodeResult(uid: uid, app: "mac") {
                            return .success(cookie: macCookie)
                        }
                        return .error(error.localizedDescription)
                    }
                } else if statusInt == -1 {
                    return .expired
                } else if statusInt == -2 {
                    return .error("Canceled on mobile app")
                }
                
                // Fallback check if cookie is returned directly in dataObj
                if let cookieObj = dataObj["cookie"] as? [String: Any], !cookieObj.isEmpty {
                    var cookieParts: [String] = []
                    for (k, v) in cookieObj {
                        cookieParts.append("\(k)=\(v)")
                    }
                    let cookieStr = cookieParts.joined(separator: "; ")
                    return .success(cookie: cookieStr)
                }
                if let uid = dataObj["UID"] as? String, let cid = dataObj["CID"] as? String, let seid = dataObj["SEID"] as? String {
                    let cookieStr = "UID=\(uid); CID=\(cid); SEID=\(seid)"
                    return .success(cookie: cookieStr)
                }
            }
            return .waiting
        } catch {
            return .error(error.localizedDescription)
        }
    }

    public func postQRCodeResult(uid: String, app: String = "web") async throws -> String {
        guard let url = URL(string: "https://passportapi.115.com/app/1.0/\(app)/1.0/login/qrcode/") else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid login URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = "app=\(app)&account=\(uid)"
        req.httpBody = bodyString.data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let stateInt = (json["state"] as? NSNumber)?.intValue ?? (json["state"] as? Bool == true ? 1 : 0)
            if stateInt == 1, let dataObj = json["data"] as? [String: Any] {
                if let cookieObj = dataObj["cookie"] as? [String: Any], !cookieObj.isEmpty {
                    var parts: [String] = []
                    for (k, v) in cookieObj {
                        parts.append("\(k)=\(v)")
                    }
                    return parts.joined(separator: "; ")
                } else if let cookieStr = dataObj["cookie"] as? String, !cookieStr.isEmpty {
                    return cookieStr
                }
            } else if stateInt == 0 {
                let msg = (json["msg"] as? String) ?? (json["error"] as? String) ?? (json["message"] as? String) ?? "Login exchange failed"
                throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }

        if let fields = http.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !cookies.isEmpty {
                let parts = cookies.map { "\($0.name)=\($0.value)" }
                return parts.joined(separator: "; ")
            }
        }

        throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract 115 login cookies"])
    }

    // MARK: - File Listing

    public func listFiles(server: ServerConfig, at path: String, cookie: String) async throws -> [VideoFile] {
        let normalized = normalizePath(path)
        var cid = "0"
        if normalized != "/" {
            if let cachedId = fileId(forPath: normalized, serverId: server.id) {
                cid = cachedId
            } else {
                let segments = normalized.components(separatedBy: "/").filter { !$0.isEmpty }
                var currentCid = "0"
                var currentPath = ""
                for seg in segments {
                    currentPath += "/" + seg
                    if let knownId = fileId(forPath: currentPath, serverId: server.id) {
                        currentCid = knownId
                    } else {
                        let subFiles = try await fetchFileList(server: server, cid: currentCid, parentPath: (currentPath as NSString).deletingLastPathComponent, cookie: cookie)
                        if let found = subFiles.first(where: { $0.name == seg && $0.type == .folder }) {
                            currentCid = found.jellyfinItemId ?? "0"
                            setFileId(currentCid, forPath: currentPath, serverId: server.id)
                        } else {
                            throw NSError(domain: "Pan115Manager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Path not found: \(normalized)"])
                        }
                    }
                }
                cid = currentCid
            }
        }

        setFileId(cid, forPath: normalized, serverId: server.id)
        return try await fetchFileList(server: server, cid: cid, parentPath: normalized, cookie: cookie)
    }

    private func fetchFileList(server: ServerConfig, cid: String, parentPath: String, cookie: String) async throws -> [VideoFile] {
        let endpoint = "https://webapi.115.com/files"
        var allFiles: [VideoFile] = []
        var offset = 0
        let limit = 100

        while true {
            var urlComponents = URLComponents(string: endpoint)!
            urlComponents.queryItems = [
                URLQueryItem(name: "aid", value: "1"),
                URLQueryItem(name: "cid", value: cid),
                URLQueryItem(name: "o", value: "user_ptime"),
                URLQueryItem(name: "asc", value: "0"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "show_dir", value: "1"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "code", value: ""),
                URLQueryItem(name: "scid", value: ""),
                URLQueryItem(name: "snap", value: "0"),
                URLQueryItem(name: "natsort", value: "1"),
                URLQueryItem(name: "record_open_time", value: "1"),
                URLQueryItem(name: "source", value: ""),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "fc_mix", value: "0"),
            ]

            guard let url = urlComponents.url else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("https://115.com", forHTTPHeaderField: "Referer")
            request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "Pan115Manager", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch file list"])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from 115"])
            }

            let isStateOk = (json["state"] as? Bool) ?? ((json["state"] as? Int) == 1)
            if !isStateOk {
                let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? (json["error"] as? String) ?? NSLocalizedString("115 session expired or invalid", comment: "")
                let errCode = (json["code"] as? Int) ?? (json["errNo"] as? Int) ?? (json["errno"] as? Int) ?? 401
                throw NSError(domain: "Pan115Manager", code: errCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            guard let items = json["data"] as? [[String: Any]] else {
                break
            }

            for item in items {
                let name = (item["n"] as? String) ?? (item["fn"] as? String) ?? ""
                guard !name.isEmpty else { continue }

                let cid = (item["cid"] as? String) ?? (item["cid"] as? Int64).map(String.init) ?? (item["cid"] as? Int).map(String.init) ?? (item["category_id"] as? String)
                let fid = (item["fid"] as? String) ?? (item["fid"] as? Int64).map(String.init) ?? (item["fid"] as? Int).map(String.init)
                let pickCode = ((item["pc"] as? String) ?? (item["pick_code"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let sha = ((item["sha"] as? String) ?? (item["sha1"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ico = ((item["ico"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let hasPid = item["pid"] != nil || item["p_id"] != nil

                // In 115 API:
                // Folders: Have folder category ID (cid), parent ID (pid), ico == "folder", and NO sha1 / pick_code.
                // Files: Have valid file ID (fid), sha1 hash, pick_code, and format-specific ico.
                var isFolder = false
                if ico == "folder" {
                    isFolder = true
                } else if hasPid {
                    isFolder = true
                } else if pickCode.isEmpty && sha.isEmpty {
                    isFolder = true
                } else {
                    isFolder = false
                }

                let size = isFolder ? 0 : ((item["s"] as? Int64) ?? Int64((item["s"] as? Int) ?? 0))
                let id = isFolder ? (cid ?? "") : (fid ?? pickCode)

                let itemPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"

                if isFolder {
                    if !id.isEmpty {
                        setFileId(id, forPath: itemPath, serverId: server.id)
                    }
                } else {
                    if !id.isEmpty {
                        setFileId(id, forPath: itemPath, serverId: server.id)
                    }
                    if !pickCode.isEmpty {
                        setPickcode(pickCode, forPath: itemPath, serverId: server.id)
                    }
                }

                var thumbURL: URL? = nil
                if let u = item["u"] as? String, !u.isEmpty, let parsed = URL(string: u) {
                    thumbURL = parsed
                } else if let thumb = item["thumb"] as? String, !thumb.isEmpty, let parsed = URL(string: thumb) {
                    thumbURL = parsed
                }

                let fileURL = URL(fileURLWithPath: itemPath)
                let type: VideoFile.FileType = isFolder ? .folder : VideoFile.FileType.determineType(from: fileURL)

                var fileDate = Date()
                if let tStr = item["t"] as? String {
                    if let ts = Double(tStr) {
                        fileDate = Date(timeIntervalSince1970: ts)
                    } else {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd HH:mm"
                        if let d = formatter.date(from: tStr) {
                            fileDate = d
                        }
                    }
                } else if let tInt = item["t"] as? Int {
                    fileDate = Date(timeIntervalSince1970: TimeInterval(tInt))
                } else if let tInt64 = item["t"] as? Int64 {
                    fileDate = Date(timeIntervalSince1970: TimeInterval(tInt64))
                }

                var videoFile = VideoFile(
                    name: name,
                    url: fileURL,
                    type: type,
                    size: size,
                    date: fileDate
                )
                videoFile.isRemote = true
                videoFile.serverType = ServerConfig.ServerType.pan115
                videoFile.jellyfinServerId = server.id.uuidString
                videoFile.jellyfinItemId = isFolder ? id : (pickCode.isEmpty ? id : pickCode)
                videoFile.serverPath = itemPath
                videoFile.customArtworkURL = thumbURL
                allFiles.append(videoFile)
            }

            let totalCount = (json["count"] as? Int) ?? allFiles.count
            offset += limit
            if offset >= totalCount || items.isEmpty {
                break
            }
        }

        return allFiles
    }

    // MARK: - Direct Playback URL (Direct CDN Stream, No Proxy)

    public func playbackURL(server: ServerConfig, at path: String, pickcode: String? = nil, cookie: String, originalOnly: Bool = false) async throws -> URL {
        var effectivePickCode = pickcode ?? self.pickcode(forPath: path, serverId: server.id)

        if effectivePickCode == nil || effectivePickCode?.isEmpty == true {
            let normalized = normalizePath(path)
            let parentPath = (normalized as NSString).deletingLastPathComponent
            if let files = try? await listFiles(server: server, at: parentPath, cookie: cookie) {
                if let matched = files.first(where: { ($0.serverPath ?? $0.url.path) == normalized || $0.name == (normalized as NSString).lastPathComponent }) {
                    effectivePickCode = matched.jellyfinItemId
                }
            }
        }

        guard let pickCode = effectivePickCode, !pickCode.isEmpty else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing pickcode for 115 file"])
        }

        // 1. Fetch direct CDN URL with Chrome Extension API (high-speed unconstrained stream)
        if let directURL = await Pan115ChromeDownloader.fetchDownloadURL(pickcode: pickCode, cookie: cookie, logURL: !originalOnly) {
            if !originalOnly { print("[Pan115Manager] Resolved 115 direct stream URL via Chrome API: \(directURL)") }
            return directURL
        }

        // 2. Fallback: Official webapi download URL
        if let fallbackURL = await fetchWebapiDownloadURL(pickcode: pickCode, cookie: cookie) {
            if !originalOnly { print("[Pan115Manager] Resolved 115 stream URL via webapi fallback: \(fallbackURL)") }
            return fallbackURL
        }

        // 3. Fallback: Official video stream API
        if !originalOnly, let videoStreamURL = await fetchVideoStreamURL(pickcode: pickCode, cookie: cookie) {
            print("[Pan115Manager] Resolved 115 stream URL via video API fallback: \(videoStreamURL)")
            return videoStreamURL
        }

        throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve 115 direct stream URL"])
    }

    private func fetchWebapiDownloadURL(pickcode: String, cookie: String) async -> URL? {
        guard let url = URL(string: "https://webapi.115.com/files/download?pickcode=\(pickcode)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? Bool, state,
               let fileURLStr = (json["file_url"] as? String) ?? (json["url"] as? String),
               !fileURLStr.isEmpty,
               let resolved = URL(string: fileURLStr) {
                return resolved
            }
        } catch {
            print("[Pan115Manager] webapi fallback error: \(error.localizedDescription)")
        }
        return nil
    }

    private func fetchVideoStreamURL(pickcode: String, cookie: String) async -> URL? {
        guard let url = URL(string: "https://v.anxia.com/webapi/files/video?pickcode=\(pickcode)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://v.anxia.com", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? Bool, state,
               let dataDict = json["data"] as? [String: Any],
               let videoUrl = (dataDict["video_url"] as? String) ?? (dataDict["url"] as? String),
               !videoUrl.isEmpty,
               let resolved = URL(string: videoUrl) {
                return resolved
            }
        } catch {
            print("[Pan115Manager] video api fallback error: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Direct Download URL

    public func rawDownloadURL(server: ServerConfig, at path: String, pickcode: String? = nil, cookie: String, originalOnly: Bool = false) async throws -> URL {
        try await playbackURL(server: server, at: path, pickcode: pickcode, cookie: cookie, originalOnly: originalOnly)
    }

    // MARK: - File Operations

    public func deleteFile(server: ServerConfig, at path: String, cookie: String) async throws {
        guard let fid = fileId(forPath: path, serverId: server.id) else {
            throw NSError(domain: "Pan115Manager", code: 404, userInfo: [NSLocalizedDescriptionKey: "File ID not found for deletion"])
        }
        guard let url = URL(string: "https://webapi.115.com/rb/delete") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        req.httpBody = "fid[0]=\(fid)&ignore_warn=1".data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete file from 115"])
        }
    }

    public func createDirectory(server: ServerConfig, at parentPath: String, name: String, cookie: String) async throws {
        let parentCid = fileId(forPath: parentPath, serverId: server.id) ?? "0"
        guard let url = URL(string: "https://webapi.115.com/files/add") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        req.httpBody = "pid=\(parentCid)&cname=\(encodedName)".data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder on 115"])
        }
    }

    public func renameFile(server: ServerConfig, at path: String, newName: String, cookie: String) async throws {
        guard let fid = fileId(forPath: path, serverId: server.id) else {
            throw NSError(domain: "Pan115Manager", code: 404, userInfo: [NSLocalizedDescriptionKey: "File ID not found for rename"])
        }
        guard let url = URL(string: "https://webapi.115.com/files/edit") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        let encodedName = newName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? newName
        req.httpBody = "fid=\(fid)&file_name=\(encodedName)".data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state else {
            throw NSError(domain: "Pan115Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to rename file on 115"])
        }
    }
}
