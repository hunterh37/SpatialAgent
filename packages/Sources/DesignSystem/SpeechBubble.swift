import SwiftUI

/// Tokens stream in; the bubble appears on the first token and never shows an empty box
/// (spec/02-interaction.md). When nothing has arrived yet it shows motion instead.
public struct SpeechBubble: View {
    private let text: String
    private let isStreaming: Bool

    public init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        Group {
            if text.isEmpty {
                ThinkingDots()
            } else {
                Text(text)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .agentGlassBackground(cornerRadius: 22)
        .animation(.easeOut(duration: 0.15), value: text)
        .accessibilityLabel(text.isEmpty ? "Thinking" : text)
    }
}

/// Shown while the character is in `thinking` and no token has arrived within 1.5s.
public struct ThinkingDots: View {
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * pulse(index))
            }
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func pulse(_ index: Int) -> Double {
        let shifted = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
        return max(0, 1 - abs(shifted - 0.5) * 2)
    }
}

#Preview("streaming") {
    VStack(spacing: 30) {
        SpeechBubble(text: "", isStreaming: true)
        SpeechBubble(text: "The kitchen light is on at eighty percent.", isStreaming: false)
    }
    .padding(60)
}
