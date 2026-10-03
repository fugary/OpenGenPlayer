import Foundation

/// CPU-only conversion for small auxiliary frames, including background PiP.
/// libmpv SW scales/YUV-converts but preserves the source transfer and primaries.
/// Decode at 16 bits before compressing luminance; never label PQ bytes as SDR.
final class MPVHDRToneMapper {
    private let linear: [Float]
    private let bt2020: Bool
    private let p3: Bool
    private static let encoded: [UInt8] = (0...8192).map {
        let x = Double($0) / 8192
        return UInt8((255 * (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)).rounded())
    }

    init?(transfer: String, primaries: String) {
        let transfer = transfer.lowercased()
        guard ["pq", "hlg"].contains(transfer), ["bt.2020", "bt.709", "display-p3"].contains(primaries) else { return nil }
        bt2020 = primaries == "bt.2020"
        p3 = primaries == "display-p3"
        linear = (0...65535).map { index in
            let signal = Double(index) / 65535
            if transfer == "pq" {
                let n = pow(signal, 1 / (2523.0 / 32))
                return Float(10000 * pow(max(n - 3424.0 / 4096, 0) / max(2413.0 / 128 - 2392.0 / 128 * n, 1e-12), 1 / (2610.0 / 16384)))
            }
            // BT.2100 HLG reference display: 1000 nit peak and system gamma 1.2.
            return Float(signal <= 0.5 ? signal * signal / 3 : (exp((signal - 0.55991073) / 0.17883277) + 0.28466892) / 12)
        }
        isHLG = transfer == "hlg"
    }
    private let isHLG: Bool

    func convert(source: UnsafePointer<UInt16>, sourceStride: Int, destination: UnsafeMutablePointer<UInt8>,
                 destinationStride: Int, width: Int, height: Int) {
        for y in 0..<height {
            let input = source.advanced(by: y * sourceStride / 2)
            let output = destination.advanced(by: y * destinationStride)
            for x in 0..<width {
                var r = linear[Int(input[4*x])], g = linear[Int(input[4*x+1])], b = linear[Int(input[4*x+2])]
                if isHLG {
                    let luminance = max(0, bt2020 ? 0.2627*r + 0.6780*g + 0.0593*b
                        : (p3 ? 0.228975*r + 0.691739*g + 0.079287*b : 0.2126*r + 0.7152*g + 0.0722*b))
                    let gain = 1000 * pow(luminance, 0.2)
                    r *= gain; g *= gain; b *= gain
                }
                if bt2020 {
                    (r, g, b) = (1.660491*r - 0.587641*g - 0.072850*b,
                                 -0.124550*r + 1.132900*g - 0.008349*b,
                                 -0.018151*r - 0.100579*g + 1.118730*b)
                } else if p3 {
                    (r, g, b) = (1.224745*r - 0.224904*g, -0.042058*r + 1.042081*g,
                                 -0.019642*r - 0.078655*g + 1.098537*b)
                }
                // Luminance-preserving Reinhard shoulder, 203 nit reference white.
                let luminance = max(0, 0.2126*r + 0.7152*g + 0.0722*b)
                let gain = 1 / (203 + luminance)
                func encode(_ value: Float) -> UInt8 {
                    Self.encoded[Int(min(1, max(0, value * gain)) * 8192)]
                }
                output[4*x] = encode(b); output[4*x+1] = encode(g); output[4*x+2] = encode(r); output[4*x+3] = 255
            }
        }
    }
}
