import SwiftUI

/// 3本指タップで出す確認用の表示。
///
/// 目を閉じて遊ぶゲームなので普段は完全に消えているが、
/// 「感じたこと」と「実際の数値」がズレている箇所を切り分けるために使う。
struct DebugOverlay: View {
    @EnvironmentObject private var engine: WalkEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("steps", "\(engine.debug.steps)")
            row("heading", String(format: "%.1f°", engine.debug.headingDegrees))
            row("position", String(format: "x %.1f  z %.1f", engine.debug.positionX, engine.debug.positionZ))
            row("speed", String(format: "%.2f m/s", engine.debug.speed))
            row("drift", String(format: "%+.2f°/step", engine.debug.driftDegrees))

            Divider().background(.white.opacity(0.2)).padding(.vertical, 4)

            row("swing", engine.debug.swingFootIsLeft ? "LEFT" : "RIGHT")
            footRow("L", down: engine.debug.leftDown, progress: engine.debug.leftProgress)
            footRow("R", down: engine.debug.rightDown, progress: engine.debug.rightProgress)

            Divider().background(.white.opacity(0.2)).padding(.vertical, 4)

            row("landmark", String(format: "%+.0f°  %.1fm",
                                   engine.debug.landmarkBearingDegrees,
                                   engine.debug.landmarkDistance))

            if !engine.supportsHaptics {
                Text("no haptics")
                    .foregroundStyle(.orange.opacity(0.8))
            }
            if let message = engine.statusMessage {
                Text(message)
                    .foregroundStyle(.orange.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .frame(maxWidth: 260, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.top, 60)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 66, alignment: .leading)
            Text(value)
        }
    }

    /// 足ごとの接地状態と、次の一歩までの踏み込み量。
    private func footRow(_ label: String, down: Bool, progress: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(down ? 0.75 : 0.2))
                .frame(width: 66, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(.white.opacity(down ? 0.45 : 0.15))
                        .frame(width: proxy.size.width * clamped01(progress))
                }
            }
            .frame(height: 6)
        }
    }
}
