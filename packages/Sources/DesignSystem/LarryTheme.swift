import SwiftUI

/// Larry's look: soft candy gradients, chunky rounded shapes, and a little bounce.
/// Kept here so the window, the ornaments, and the map rows can't drift apart.
public enum Larry {
    public static let name = "Larry"
    public static let tagline = "your room buddy"

    public static let bubblegum = Color(red: 1.00, green: 0.45, blue: 0.68)
    public static let sky = Color(red: 0.36, green: 0.72, blue: 1.00)
    public static let mint = Color(red: 0.35, green: 0.90, blue: 0.72)
    public static let sunshine = Color(red: 1.00, green: 0.82, blue: 0.30)
    public static let grape = Color(red: 0.64, green: 0.51, blue: 1.00)

    public static var candy: LinearGradient {
        LinearGradient(colors: [bubblegum, grape, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public static var xpBar: LinearGradient {
        LinearGradient(colors: [mint, sunshine, bubblegum], startPoint: .leading, endPoint: .trailing)
    }
}

/// A chunky pastel card. Every panel in the window uses it so the surface reads as one toy.
public struct LarryCard<Content: View>: View {
    private let tint: Color
    private let content: Content

    public init(tint: Color = Larry.grape, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1.5)
            )
    }
}

/// Larry himself: two eyes, a grin, and a bob. The immersive character is the real one —
/// this is the badge that keeps him present while the space is closed.
public struct LarryAvatar: View {
    private let isExcited: Bool
    private let size: CGFloat
    @State private var bob = false

    public init(isExcited: Bool = false, size: CGFloat = 64) {
        self.isExcited = isExcited
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(Larry.candy)
            Circle().fill(.white.opacity(0.35)).frame(width: size * 0.3).offset(x: -size * 0.16, y: -size * 0.2)
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: -size * 0.06)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.34, height: size * (isExcited ? 0.18 : 0.08))
                .offset(y: size * 0.2)
        }
        .frame(width: size, height: size)
        .scaleEffect(bob ? 1.05 : 0.97)
        .animation(.easeInOut(duration: isExcited ? 0.45 : 1.6).repeatForever(autoreverses: true), value: bob)
        .onAppear { bob = true }
        .accessibilityLabel(Larry.name)
    }

    private var eye: some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.13, height: size * 0.2)
    }
}

/// Progress toward nothing in particular — it tracks how much Larry has been talked to.
/// Purely cosmetic on purpose: no behaviour should ever depend on the number.
public struct LarryXPBar: View {
    private let level: Int
    private let progress: Double

    public init(level: Int, progress: Double) {
        self.level = level
        self.progress = min(max(progress, 0), 1)
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text("LV \(level)")
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(Larry.sunshine)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(Larry.xpBar).frame(width: max(8, geo.size.width * progress))
                }
            }
            .frame(height: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: progress)
        }
        .accessibilityIdentifier("larry.xp")
    }
}
