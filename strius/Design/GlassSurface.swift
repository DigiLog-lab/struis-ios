import SwiftUI

enum GlassSurfaceStyle {
    case regular
    case thin
    case clear

    fileprivate var native: Glass {
        switch self {
        case .regular: .regular
        case .thin: .regular.tint(Color.primary.opacity(0.04))
        case .clear: .clear
        }
    }
}

struct GlassSurface<S: Shape>: ViewModifier {
    let style: GlassSurfaceStyle
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        content.glassEffect(style.native.interactive(interactive), in: shape)
    }
}

extension View {
    func glassSurface(
        _ style: GlassSurfaceStyle = .regular,
        in shape: some Shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
        interactive: Bool = false
    ) -> some View {
        modifier(GlassSurface(style: style, shape: shape, interactive: interactive))
    }
}
