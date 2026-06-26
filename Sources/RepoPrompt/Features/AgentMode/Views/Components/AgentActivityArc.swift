import SwiftUI

/// Tiny SwiftUI-only activity indicator for exact-height Agent Mode chrome.
/// Native `ProgressView` can trip AppKit min/max layout assertions in these slots.
struct AgentActivityArc: View {
    var tint: Color = .accentColor
    var size: CGFloat = 15
    var lineWidth: CGFloat = 1.5
    var label: String = "Running"

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                tint.opacity(0.75),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityLabel(label)
    }
}
