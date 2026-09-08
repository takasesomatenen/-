import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

/// 探索体験の中枢。
///
/// 役割:
/// 1. 指の座標とターゲット座標から「距離」と「接近速度」を求める
/// 2. それを触覚（強度／鋭さ）と音（ピッチ／音量）に連続的にマッピングする
/// 3. 到達判定とラウンド進行を管理する
///
/// 触覚設計のコア:
/// - **距離 → 強度(intensity)**: 近いほど強い。離散的なレーン分けはせず、常に連続階調。
/// - **接近／離反 → 鋭さ(sharpness)**: 近づいている間は鋭さを下げて丸く滑らかに、
///   遠ざかっている間は鋭さを上げてざらつかせる。
/// - **遠いほど不規則**: 遠距離ではゆらぎ（ランダムウォーク）を混ぜて「掴みどころのなさ」を出す。
@MainActor
final class ExplorationEngine: ObservableObject {

    enum Phase: Equatable {
        /// タイトル画面
        case title
        /// 探索中
        case exploring
        /// 到達直後の余韻
        case arrived
    }

    /// デバッグ表示用のスナップショット。
    struct DebugSnapshot: Equatable {
        var hasTarget: Bool = false
        var target: CGPoint = .zero
        var touch: CGPoint?
        var arrivalRadius: Double = 0
        var distance: Double = 0
        var normalizedDistance: Double = 1
        var intensity: Double = 0
        var sharpness: Double = 0
        var approachRate: Double = 0
        var envelope: Double = 0
    }

    // MARK: - 公開状態

    @Published private(set) var phase: Phase = .title
    @Published private(set) var foundCount: Int = 0
    @Published private(set) var debug = DebugSnapshot()
    @Published var isDebugVisible: Bool = Tuning.Debug.startVisible

    /// Core Haptics が使えるか（シミュレータでは false）。
    var supportsHaptics: Bool { haptics.supportsHaptics }
    /// 触覚／音まわりの直近のメッセージ（デバッグ表示用）。
    var statusMessage: String? { haptics.lastMessage ?? audio.lastMessage }

    // MARK: - 内部

    private let haptics = HapticsController()
    private let audio = AudioController()
    private let ticker = DisplayLinkDriver()

    private var canvasSize: CGSize = .zero
    private var hasTarget = false
    private var target: CGPoint = .zero
    private var touch: CGPoint?

    private var lastNormalizedDistance: Double = 1
    private var smoothedApproachRate: Double = 0
    private var smoothedIntensity: Double = 0
    private var smoothedSharpness: Double = Tuning.Haptics.neutralSharpness
    private var envelope: Double = 0
    private var jitter: Double = 0
    private var arrivalEndTime: CFTimeInterval?
    private var isRuntimeActive = false

    init() {
        ticker.onTick = { [weak self] dt in
            self?.tick(dt)
        }
    }

    // MARK: - 画面からの入力

    /// 探索画面のサイズが確定／変化したときに呼ぶ。
    func setCanvasSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let previousSize = canvasSize
        canvasSize = size

        if phase != .title {
            if !hasTarget {
                spawnTarget()
            } else if previousSize != size, previousSize.width > 1, previousSize.height > 1 {
                // 回転などでサイズが変わってもターゲットは失わず、相対位置を保つ。
                target = CGPoint(
                    x: target.x / previousSize.width * size.width,
                    y: target.y / previousSize.height * size.height
                )
            }
            startRuntime()
        }
        publishDebugSnapshot()
    }

    /// DragGesture の onChanged から呼ぶ。
    func updateTouch(_ location: CGPoint) {
        if touch == nil, hasTarget {
            // 指を置いた瞬間は「前フレームの距離」が無いので、接近速度の暴発を防ぐ。
            lastNormalizedDistance = normalizedDistance(at: location)
            smoothedApproachRate = 0
        }
        touch = location
    }

    /// DragGesture の onEnded から呼ぶ。
    func endTouch() {
        touch = nil
        smoothedApproachRate = 0
    }

    // MARK: - ラウンド進行

    func beginSession() {
        foundCount = 0
        hasTarget = false
        touch = nil
        envelope = 0
        smoothedIntensity = 0
        smoothedSharpness = Tuning.Haptics.neutralSharpness
        arrivalEndTime = nil
        phase = .exploring
        if canvasSize.width > 1 {
            spawnTarget()
            startRuntime()
        }
    }

    func returnToTitle() {
        stopRuntime()
        phase = .title
        hasTarget = false
        touch = nil
        envelope = 0
        smoothedIntensity = 0
        arrivalEndTime = nil
        publishDebugSnapshot()
    }

    /// ターゲットを新しい場所に置く。
    /// 直前のターゲットと今の指の位置からは一定距離離す（同じ場所を連続で出さない）。
    private func spawnTarget() {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }

        let shortSide = Double(min(canvasSize.width, canvasSize.height))
        let margin = shortSide * Tuning.Space.spawnMarginRatio
        let separation = shortSide * Tuning.Space.respawnSeparationRatio

        let minX = margin
        let maxX = max(Double(canvasSize.width) - margin, margin + 1)
        let minY = margin
        let maxY = max(Double(canvasSize.height) - margin, margin + 1)

        var avoid: [CGPoint] = []
        if hasTarget { avoid.append(target) }
        if let touch = touch { avoid.append(touch) }

        var best = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        var bestScore = -Double.infinity

        // ランダムに候補を出し、条件を満たしたら即採用。ダメでも一番マシな候補を使う。
        for _ in 0..<40 {
            let candidate = CGPoint(
                x: Double.random(in: minX...maxX),
                y: Double.random(in: minY...maxY)
            )
            let score = avoid.map { candidate.distance(to: $0) }.min() ?? .infinity
            if score > bestScore {
                bestScore = score
                best = candidate
            }
            if score >= separation { break }
        }

        target = best
        hasTarget = true
        lastNormalizedDistance = touch.map { normalizedDistance(at: $0) } ?? 1
        smoothedApproachRate = 0
        jitter = 0
    }

    // MARK: - アプリのライフサイクル

    func handleAppDidBecomeActive() {
        guard phase != .title else { return }
        startRuntime()
    }

    func handleAppWillResignActive() {
        // バックグラウンドでは触覚も音も止める（そもそもOSが許可しない）。
        touch = nil
        envelope = 0
        smoothedIntensity = 0
        stopRuntime()
    }

    private func startRuntime() {
        guard !isRuntimeActive else { return }
        isRuntimeActive = true
        haptics.prepare()
        haptics.startContinuous()
        audio.start()
        audio.update(proximity: 0, gain: 0)
        ticker.start()
    }

    private func stopRuntime() {
        guard isRuntimeActive else { return }
        isRuntimeActive = false
        ticker.stop()
        haptics.shutdown()
        audio.update(proximity: 0, gain: 0)
        audio.stop()
    }

    // MARK: - 毎フレームの更新

    private func tick(_ rawDelta: CFTimeInterval) {
        // フレーム落ちや復帰直後の異常な dt をクランプする。
        let dt = clamped(Double(rawDelta), 1.0 / 240.0, 1.0 / 20.0)

        switch phase {
        case .title:
            return

        case .arrived:
            // 余韻中は連続振動を静かに引っ込める。
            envelope = smoothed(current: envelope, target: 0, tau: Tuning.Haptics.releaseFade, dt: dt)
            applyOutputs(proximity: 0)
            if let end = arrivalEndTime, CACurrentMediaTime() >= end {
                arrivalEndTime = nil
                spawnTarget()
                phase = .exploring
                haptics.startContinuous()
            }

        case .exploring:
            guard hasTarget else { return }
            updateJitter(dt: dt)

            guard let touch = touch else {
                // 指が離れている間はフェードアウトのみ（音も触覚も消える）。
                envelope = smoothed(current: envelope, target: 0, tau: Tuning.Haptics.releaseFade, dt: dt)
                applyOutputs(proximity: 0)
                return
            }

            let distance = touch.distance(to: target)
            let normalized = clamped01(distance / senseRange)

            // 接近速度: 正 = 近づいている、負 = 遠ざかっている。
            let rawRate = (lastNormalizedDistance - normalized) / dt
            lastNormalizedDistance = normalized
            smoothedApproachRate = smoothed(
                current: smoothedApproachRate,
                target: rawRate,
                tau: Tuning.Haptics.approachRateSmoothing,
                dt: dt
            )

            let proximity = 1 - normalized

            // --- 距離 → 強度 -------------------------------------------------
            var intensityTarget = Tuning.Haptics.minIntensity
                + (Tuning.Haptics.maxIntensity - Tuning.Haptics.minIntensity)
                * pow(proximity, Tuning.Haptics.intensityGamma)
            // 遠いほど不規則に（ゆらぎを乗せる）。
            let jitterAmount = normalized * Tuning.Haptics.farJitterAmount
            intensityTarget = clamped01(intensityTarget * (1 + jitter * jitterAmount))

            // --- 接近／離反 → 鋭さ --------------------------------------------
            let direction = clamped(smoothedApproachRate / Tuning.Haptics.approachRateFullScale, -1, 1)
            var sharpnessTarget: Double
            if direction >= 0 {
                sharpnessTarget = lerp(Tuning.Haptics.neutralSharpness,
                                       Tuning.Haptics.approachingSharpness, direction)
            } else {
                sharpnessTarget = lerp(Tuning.Haptics.neutralSharpness,
                                       Tuning.Haptics.recedingSharpness, -direction)
            }
            sharpnessTarget = clamped01(
                sharpnessTarget + jitter * jitterAmount * Tuning.Haptics.farJitterSharpnessScale
            )

            smoothedIntensity = smoothed(current: smoothedIntensity, target: intensityTarget,
                                         tau: Tuning.Haptics.intensitySmoothing, dt: dt)
            smoothedSharpness = smoothed(current: smoothedSharpness, target: sharpnessTarget,
                                         tau: Tuning.Haptics.sharpnessSmoothing, dt: dt)
            envelope = smoothed(current: envelope, target: 1,
                                tau: Tuning.Haptics.attackTime, dt: dt)

            applyOutputs(proximity: proximity)

            if distance <= arrivalRadius {
                arrive()
            }
        }
    }

    /// 遠距離での「不規則さ」を作るランダムウォーク（-1...1）。
    private func updateJitter(dt: Double) {
        let noise = Double.random(in: -1...1)
        jitter = clamped(
            smoothed(current: jitter, target: noise, tau: Tuning.Haptics.farJitterSmoothing, dt: dt),
            -1, 1
        )
    }

    private func applyOutputs(proximity: Double) {
        let intensity = smoothedIntensity * envelope
        haptics.updateContinuous(intensity: intensity, sharpness: smoothedSharpness)
        audio.update(proximity: proximity, gain: envelope)
        publishDebugSnapshot(intensity: intensity, proximity: proximity)
    }

    private func arrive() {
        phase = .arrived
        foundCount += 1
        arrivalEndTime = CACurrentMediaTime() + Tuning.Round.arrivalHoldSeconds

        // 連続振動をいったん止めてから、到達パターンをはっきり鳴らす。
        haptics.stopContinuous()
        haptics.playArrival()
        audio.playArrivalChime()
    }

    // MARK: - 距離計算

    /// 触覚が反応する最大距離（画面対角線ベース）。
    private var senseRange: Double {
        let width = Double(canvasSize.width)
        let height = Double(canvasSize.height)
        let diagonal = (width * width + height * height).squareRoot()
        return max(diagonal * Tuning.Space.senseRangeRatio, 1)
    }

    /// 到達判定の半径。
    private var arrivalRadius: Double {
        max(Double(min(canvasSize.width, canvasSize.height)) * Tuning.Space.arrivalRadiusRatio, 1)
    }

    private func normalizedDistance(at point: CGPoint) -> Double {
        guard hasTarget else { return 1 }
        return clamped01(point.distance(to: target) / senseRange)
    }

    // MARK: - デバッグ

    private func publishDebugSnapshot(intensity: Double? = nil, proximity: Double? = nil) {
        // デバッグ非表示のときは SwiftUI の再描画を起こさない。
        guard isDebugVisible else { return }
        var snapshot = DebugSnapshot()
        snapshot.hasTarget = hasTarget
        snapshot.target = target
        snapshot.touch = touch
        snapshot.arrivalRadius = arrivalRadius
        snapshot.distance = touch.map { $0.distance(to: target) } ?? 0
        snapshot.normalizedDistance = proximity.map { 1 - $0 } ?? lastNormalizedDistance
        snapshot.intensity = intensity ?? (smoothedIntensity * envelope)
        snapshot.sharpness = smoothedSharpness
        snapshot.approachRate = smoothedApproachRate
        snapshot.envelope = envelope
        if snapshot != debug {
            debug = snapshot
        }
    }

    /// 3本指タップなどから呼ばれるデバッグ表示トグル。
    func toggleDebug() {
        isDebugVisible.toggle()
        publishDebugSnapshot()
    }
}
