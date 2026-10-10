import SwiftUI

struct LiquidWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                baseFill

                ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                    RadialGradient(
                        colors: [stop.color.opacity(0.9), stop.color.opacity(0)],
                        center: stop.unit,
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * stop.radiusFactor
                    )
                    .blendMode(.plusLighter)
                }
            }
            .blur(radius: 48)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var baseFill: Color {
        scheme == .dark
            ? Color(red: 0.164, green: 0.094, blue: 0.086)
            : Color(red: 1.0, green: 0.957, blue: 0.890)
    }

    private var stops: [Stop] {
        if scheme == .dark {
            return [
                Stop(color: Color(red: 0.227, green: 0.102, blue: 0.145), unit: .init(x: 0.12, y: 0.18), radiusFactor: 0.65),
                Stop(color: Color(red: 0.353, green: 0.176, blue: 0.176), unit: .init(x: 0.85, y: 0.05), radiusFactor: 0.55),
                Stop(color: Color(red: 0.431, green: 0.227, blue: 0.196), unit: .init(x: 0.92, y: 0.55), radiusFactor: 0.70),
                Stop(color: Color(red: 0.235, green: 0.161, blue: 0.282), unit: .init(x: 0.20, y: 0.65), radiusFactor: 0.60),
                Stop(color: Color(red: 0.117, green: 0.164, blue: 0.290), unit: .init(x: 0.65, y: 0.92), radiusFactor: 0.70),
                Stop(color: Color(red: 0.164, green: 0.094, blue: 0.086), unit: .init(x: 0.45, y: 0.40), radiusFactor: 0.80)
            ]
        }
        return [
            Stop(color: Color(red: 1.0, green: 0.847, blue: 0.722), unit: .init(x: 0.10, y: 0.15), radiusFactor: 0.70),
            Stop(color: Color(red: 1.0, green: 0.710, blue: 0.537), unit: .init(x: 0.88, y: 0.08), radiusFactor: 0.55),
            Stop(color: Color(red: 0.941, green: 0.541, blue: 0.498), unit: .init(x: 0.92, y: 0.55), radiusFactor: 0.60),
            Stop(color: Color(red: 0.769, green: 0.541, blue: 0.761), unit: .init(x: 0.18, y: 0.70), radiusFactor: 0.55),
            Stop(color: Color(red: 0.557, green: 0.647, blue: 0.839), unit: .init(x: 0.65, y: 0.95), radiusFactor: 0.60),
            Stop(color: Color(red: 1.0, green: 0.957, blue: 0.890), unit: .init(x: 0.50, y: 0.45), radiusFactor: 0.90)
        ]
    }

    private struct Stop {
        let color: Color
        let unit: UnitPoint
        let radiusFactor: CGFloat
    }
}

#if DEBUG
#Preview("Liquid Wallpaper — Light") {
    LiquidWallpaper()
        .preferredColorScheme(.light)
}

#Preview("Liquid Wallpaper — Dark") {
    LiquidWallpaper()
        .preferredColorScheme(.dark)
}
#endif
