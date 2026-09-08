import SwiftUI

/// 開発中だけ表示する可視化レイヤ。
/// 3本指タップ（またはタイトル長押し）で切り替わる。
struct DebugOverlay: View {
    @EnvironmentObject private var engine: ExplorationEngine

    var body: some View {
        let debug = engine.debug

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                guard debug.hasTarget else { return }

                // 感知範囲のうっすらしたグラデーション（近さの目安）。
                let glowRadius = CGFloat(debug.arrivalRadius * 6)
                let glow = Path(ellipseIn: CGRect(
                    x: debug.target.x - glowRadius, y: debug.target.y - glowRadius,
                    width: glowRadius * 2, height: glowRadius * 2))
                context.fill(glow, with: .radialGradient(
                    Gradient(colors: [.green.opacity(0.16), .clear]),
                    center: debug.target, startRadius: 0, endRadius: glowRadius))

                // 到達判定の円。
                let radius = CGFloat(debug.arrivalRadius)
                let circle = Path(ellipseIn: CGRect(
                    x: debug.target.x - radius, y: debug.target.y - radius,
                    width: radius * 2, height: radius * 2))
                context.stroke(circle, with: .color(.green.opacity(0.8)), lineWidth: 1.5)

                // ターゲット中心。
                let dot = Path(ellipseIn: CGRect(
                    x: debug.target.x - 3, y: debug.target.y - 3, width: 6, height: 6))
                context.fill(dot, with: .color(.green))

                if let touch = debug.touch {
                    var line = Path()
                    line.move(to: touch)
                    line.addLine(to: debug.target)
                    context.stroke(line, with: .color(.white.opacity(0.25)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    let finger = Path(ellipseIn: CGRect(
                        x: touch.x - 14, y: touch.y - 14, width: 28, height: 28))
                    context.stroke(finger, with: .color(.cyan.opacity(0.85)), lineWidth: 1.5)
                }
            }

            panel
                .padding(14)
        }
    }

    private var panel: some View {
        let debug = engine.debug
        return VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)

            row("found", "\(engine.foundCount)")
            row("dist", String(format: "%.1f pt", debug.distance))
            row("norm", String(format: "%.3f", debug.normalizedDistance))
            row("rate", String(format: "%+.2f", debug.approachRate))
            row("env", String(format: "%.2f", debug.envelope))

            meter(label: "intensity", value: debug.intensity, tint: .green)
            meter(label: "sharpness", value: debug.sharpness, tint: .orange)

            if !engine.supportsHaptics {
                Text("haptics: unavailable (simulator?)")
                    .foregroundStyle(.orange)
            }
            if let message = engine.statusMessage {
                Text(message)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.55))
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 8)
            Text(value)
        }
        .frame(width: 170)
    }

    private func meter(label: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 8)
                Text(String(format: "%.3f", value))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint.opacity(0.8))
                        .frame(width: proxy.size.width * CGFloat(clamped01(value)))
                }
            }
            .frame(height: 4)
        }
        .frame(width: 170)
    }
}
