import SwiftUI
import GenPlayerShell

struct CustomProgressBar: View {
    @Binding var value: Float
    var onEditingChanged: (Bool) -> Void
    var duration: Double = 0
    var bufferedRanges: [MPVBufferedRange] = []
    var onScrubBegan: (() -> Void)? = nil
    var onScrubTimeChanged: ((Double) -> Void)? = nil
    var onScrubEnded: (() -> Void)? = nil
    var onTapSeek: ((Double) -> Void)? = nil
    @State private var isEditing = false
    private let dragActivationDistance: CGFloat = 8

    private var clampedValue: CGFloat {
        CGFloat(min(max(0.0, value), 1.0))
    }

    var body: some View {
        GeometryReader { geometry in
            let barWidth = max(geometry.size.width, 1)
            let progressWidth = clampedValue * barWidth
            let thumbSize: CGFloat = isEditing ? 14 : 12
            let thumbX = min(max(0, progressWidth - (thumbSize / 2)), barWidth - thumbSize)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: isEditing ? 6 : 5)

                MPVBufferedTrack(ranges: bufferedRanges, duration: duration)
                    .frame(height: isEditing ? 6 : 5)

                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.72), Color.white]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(progressWidth, 0), height: isEditing ? 6 : 5)
                    .shadow(color: Color.white.opacity(isEditing ? 0.42 : 0.22), radius: isEditing ? 6 : 3)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.16), lineWidth: 0.5)
                    )
                    .shadow(color: Color.white.opacity(isEditing ? 0.58 : 0.3), radius: isEditing ? 8 : 4)
                    .shadow(color: Color.black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                    .offset(x: thumbX)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newProgress = min(max(0, Float(drag.location.x / barWidth)), 1)
                        let movedEnough = abs(drag.translation.width) >= dragActivationDistance ||
                            abs(drag.translation.height) >= dragActivationDistance

                        if !isEditing, movedEnough {
                            isEditing = true
                            onScrubBegan?()
                            onEditingChanged(true)
                        }

                        guard isEditing else { return }

                        value = newProgress
                        onScrubTimeChanged?(Double(newProgress) * duration)
                    }
                    .onEnded { drag in
                        if isEditing {
                            let finalProgress = min(max(0, Float(drag.location.x / barWidth)), 1)
                            value = finalProgress
                            onScrubTimeChanged?(Double(finalProgress) * duration)
                            onScrubEnded?()
                            isEditing = false
                            onEditingChanged(false)
                        } else {
                            let tappedProgress = min(max(0, Float(drag.location.x / barWidth)), 1)
                            onTapSeek?(Double(tappedProgress) * duration)
                        }
                    }
            )
        }
    }
}
