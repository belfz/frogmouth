import FrogmouthCore
import SwiftUI

struct TrimScrubber: View {
    let duration: TimeInterval
    let trim: TrimRange
    let playhead: TimeInterval
    let onDraftTrim: (TrimRange) -> Void
    let onCommitTrim: (TrimRange) -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var trimAtDragStart: TrimRange?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let startX = x(for: trim.start, width: width)
                let endX = x(for: trim.end, width: width)
                let playheadX = x(for: min(max(playhead, 0), duration), width: width)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            onSeek(time(for: value.location.x, width: width))
                        })
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 10)
                        .offset(y: 15)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(1, endX - startX), height: 10)
                        .offset(x: startX, y: 15)

                    handle(at: startX, systemName: "chevron.right.2")
                        .gesture(trimGesture(edge: .start, width: width))
                    handle(at: endX, systemName: "chevron.left.2")
                        .gesture(trimGesture(edge: .end, width: width))

                    Rectangle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1)
                        .frame(width: 2, height: 34)
                        .offset(x: playheadX - 1, y: 3)
                }
            }
            .frame(height: 42)

            HStack {
                Text(formatTime(trim.start))
                Spacer()
                Text("Playhead \(formatTime(playhead))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(trim.end))
            }
            .font(.caption.monospacedDigit())
        }
    }

    private enum Edge { case start, end }

    private func handle(at x: CGFloat, systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 34)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
            .offset(x: x - 9, y: 3)
    }

    private func trimGesture(edge: Edge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if trimAtDragStart == nil { trimAtDragStart = trim }
                guard let initial = trimAtDragStart else { return }
                let delta = Double(value.translation.width / width) * duration
                var updated = initial
                switch edge {
                case .start:
                    updated.start = min(max(0, initial.start + delta), updated.end - 0.1)
                case .end:
                    updated.end = max(min(duration, initial.end + delta), updated.start + 0.1)
                }
                onDraftTrim(updated)
            }
            .onEnded { _ in
                if let trimAtDragStart { onCommitTrim(trimAtDragStart) }
                trimAtDragStart = nil
            }
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(time / duration)
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * duration), duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00.000" }
        let totalMilliseconds = Int((max(0, seconds) * 1_000).rounded())
        let minutes = totalMilliseconds / 60_000
        let remainder = totalMilliseconds % 60_000
        return String(format: "%02d:%02d.%03d", minutes, remainder / 1_000, remainder % 1_000)
    }
}
