import Foundation
import CoreText

/// iOS plain-text subtitles share VLC's video-relative EM size. libass uses
/// ascender + descender instead of EM, so equal numeric sizes are not equivalent.
public struct IOSSubtitleTypography {
    public let fontFamily: String
    public let assHeightToEMRatio: Double

    public init(fontURL: URL?) {
        let font: CTFont
        if let fontURL,
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            let registrationError = error?.takeRetainedValue()
            if registered || registrationError.map({ CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue }) == true {
                font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
            } else {
                font = CTFontCreateWithName("HelveticaNeue" as CFString, 1000, nil)
            }
        } else {
            font = CTFontCreateWithName("HelveticaNeue" as CFString, 1000, nil)
        }
        fontFamily = CTFontCopyFamilyName(font) as String

        // libass ass_font.c uses OS/2 usWinAscent/usWinDescent, then requests
        // FT_SIZE_REQUEST_TYPE_REAL_DIM. VLC FreeType uses FT_Set_Pixel_Sizes.
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           table.count >= 78, CTFontGetUnitsPerEm(font) > 0 {
            let ascent = Int(table[74]) << 8 | Int(table[75])
            let descent = Int(table[76]) << 8 | Int(table[77])
            let ratio = Double(ascent + descent) / Double(CTFontGetUnitsPerEm(font))
            assHeightToEMRatio = ratio > 0 ? ratio : 1
        } else {
            assHeightToEMRatio = Double(CTFontGetAscent(font) + CTFontGetDescent(font)) / 1000
        }
    }

    /// VLCKit's font-size API sets freetype-rel-fontsize: EM = videoShortSide / divisor.
    /// mpv uses a 720-high reference canvas; don't include portrait black bars,
    /// Retina scale, source resolution or the simulator's reduced render size.
    public func mpvFontSize(vlcRelativeDivisor: Double, videoSize: CGSize = .zero) -> Double {
        let divisor = vlcRelativeDivisor.isFinite && vlcRelativeDivisor > 0 ? vlcRelativeDivisor : 22
        // VLC caps portrait source media by its width (not by window orientation).
        let portraitScale = videoSize.width.isFinite && videoSize.height.isFinite &&
            videoSize.width > 0 && videoSize.height > 0
            ? min(1, videoSize.width / videoSize.height) : 1
        return 720 / divisor * assHeightToEMRatio * Double(portraitScale)
    }
}
