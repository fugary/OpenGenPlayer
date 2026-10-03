import SwiftUI

/// Decorative only: gestures and focus remain owned by each platform's original slider.
public struct MPVBufferedTrack: View {
    public let ranges: [MPVBufferedRange]
    public let duration: Double
    public var highContrast: Bool
    public init(ranges: [MPVBufferedRange], duration: Double, highContrast: Bool = false) {
        self.ranges = ranges; self.duration = duration; self.highContrast = highContrast
    }
    public var body: some View {
        GeometryReader { geometry in
            let segments = MPVBufferedRange.normalized(ranges, duration: duration)
            ZStack(alignment: .leading) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(highContrast ? 0.85 : 0.46))
                        .frame(width: max(0, geometry.size.width * CGFloat((segments[index].end - segments[index].start) / duration)))
                        .offset(x: geometry.size.width * CGFloat(segments[index].start / duration))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
