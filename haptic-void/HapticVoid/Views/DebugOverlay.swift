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

            row("beacon", String(format: "%+.0f°  %.1fm",
                                 engine.debug.beaconBearingDegrees,
                                 engine.debug.beaconDistance))

            // 実際に回れていたのか、まっすぐ歩けていたのかを目で確かめるための小さな地図。
            WalkMap(trail: engine.trail,
                    position: CGPoint(x: engine.debug.positionX, y: engine.debug.positionZ),
                    headingDegrees: engine.debug.headingDegrees)
                .frame(height: 150)
                .padding(.top, 6)

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

/// 歩いた軌跡を上から見た小さな地図。
///
/// 触覚と音だけでは「本当に回れていたのか」「まっすぐ歩けていたのか」が確かめられないので、
/// 感覚と実際の挙動を突き合わせるために描いている。上が北。
private struct WalkMap: View {
    let trail: [CGPoint]
    /// 現在地（x = 東, y = 北。メートル）
    let position: CGPoint
    let headingDegrees: Double

    /// 表示範囲の下限と上限（メートル）。
    /// 下限が無いと歩き始めに極端に拡大され、上限が無いと遠い基準音に引っ張られて軌跡が潰れる。
    private let minimumSpan: Double = 12
    private let maximumSpan: Double = 40

    var body: some View {
        Canvas { context, size in
            let beacons = Tuning.Audio.Space.beacons.map { CGPoint(x: $0.x, y: $0.z) }
            let points = trail + [position] + beacons

            var minX = points.map(\.x).min() ?? 0
            var maxX = points.map(\.x).max() ?? 0
            var minY = points.map(\.y).min() ?? 0
            var maxY = points.map(\.y).max() ?? 0

            var centerX = Double(minX + maxX) * 0.5
            var centerY = Double(minY + maxY) * 0.5
            var span = max(Double(maxX - minX), Double(maxY - minY))

            if span > maximumSpan {
                // 広がりすぎたら自分を中心に切り取る（軌跡が見えなくなるのを防ぐ）。
                span = maximumSpan
                centerX = Double(position.x)
                centerY = Double(position.y)
            }
            span = max(span, minimumSpan)

            let inset: Double = 10
            let scale = (Double(min(size.width, size.height)) - inset * 2) / span
            let midX = Double(size.width) * 0.5
            let midY = Double(size.height) * 0.5

            // ワールド（x=東, y=北）→ 画面（右=東, 上=北）
            func project(_ p: CGPoint) -> CGPoint {
                CGPoint(x: midX + (Double(p.x) - centerX) * scale,
                        y: midY - (Double(p.y) - centerY) * scale)
            }

            // 枠と北の印
            let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
            context.stroke(frame, with: .color(.white.opacity(0.12)), lineWidth: 1)
            context.draw(Text("N").font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25)),
                         at: CGPoint(x: size.width - 10, y: 9))

            // 基準音
            for beacon in beacons {
                let p = project(beacon)
                let r: Double = 3
                let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                context.stroke(circle, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }

            // 軌跡
            if trail.count > 1 {
                var path = Path()
                path.move(to: project(trail[0]))
                for point in trail.dropFirst() {
                    path.addLine(to: project(point))
                }
                context.stroke(path, with: .color(.white.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }

            // 現在地と向き
            let here = project(position)
            let dot = Path(ellipseIn: CGRect(x: here.x - 2.5, y: here.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(.white.opacity(0.85)))

            let radians = headingDegrees * .pi / 180
            var heading = Path()
            heading.move(to: here)
            // 北が上、時計回りが正。
            heading.addLine(to: CGPoint(x: here.x + sin(radians) * 12,
                                        y: here.y - cos(radians) * 12))
            context.stroke(heading, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
    }
}
