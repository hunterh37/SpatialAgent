import SwiftUI

/// `glassBackgroundEffect` is visionOS-only. The shim keeps `DesignSystem` compiling — and
/// therefore previewable and testable — on macOS, so views are not gated behind a simulator.
public extension View {
    @ViewBuilder
    func agentGlassBackground(cornerRadius: CGFloat = 22) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
        #else
        background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        #endif
    }
}
