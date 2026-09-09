import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

/// 歩行体験の中枢。
///
/// 入力モデル:
/// - **前進**: 左右の親指を交互に下へ払う。下方向の動きだけが推進力になる（上へ戻す動作は空振り＝足を戻す動作）。
///   同じ足を続けて使うとゲインが落ちるので、左右交互でないと前へ進まない。
/// - **回頭**: 両親指を結ぶ線＝肩のライン。この線が回った角度ぶん、進行方向も回る。
///   片方を軸にしてもう片方を動かせばその場で回頭でき、指を置き直せば基準が取り直されるので、
///   ハンドルを持ち替えるように何度でも回り続けられる。
/// - **蛇行**: 目を閉じて歩くと人間はまっすぐ歩けない。これを一歩ごとのランダムウォークとして入れてある。
///   左右対称に払っても少しずつ逸れるので、数歩ごとに聴き直して直す必要が生まれる。
@MainActor
final class WalkEngine: ObservableObject {

    enum Phase: Equatable {
        case title
        case walking
    }

    enum Foot: Equatable {
        case left, right
        var opposite: Foot { self == .left ? .right : .left }
    }

    /// デバッグ表示用のスナップショット。
    struct DebugSnapshot: Equatable {
        var positionX: Double = 0
        var positionZ: Double = 0
        var headingDegrees: Double = 0
        var steps: Int = 0
        var leftDown: Bool = false
        var rightDown: Bool = false
        var leftProgress: Double = 0
        var rightProgress: Double = 0
        var swingFootIsLeft: Bool = true
        var speed: Double = 0
        var driftDegrees: Double = 0
        var landmarkBearingDegrees: Double = 0
        var landmarkDistance: Double = 0
    }

    // MARK: - 公開状態

    @Published private(set) var phase: Phase = .title
    @Published private(set) var stepCount: Int = 0
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

    /// 現在地（メートル）。x = 東、z = 北。
    private var positionX: Double = 0
    private var positionZ: Double = 0
    /// 進行方向（ラジアン）。0 = 北、時計回りが正。ラップさせずに保持する（平滑化のため）。
    private var heading: Double = 0

    /// 足ごとの状態。
    private struct FootState {
        var touchID: ObjectIdentifier?
        var location: CGPoint = .zero
        var previousLocation: CGPoint = .zero
        var strokeProgress: Double = 0
        var isDown: Bool { touchID != nil }
    }
    private var left = FootState()
    private var right = FootState()

    /// 直前に着地した足。次に踏むべき足（遊脚）はこの反対側。
    private var lastSteppedFoot: Foot = .right

    /// 肩のラインの前フレームの角度。両親指が乗っていないときは nil。
    private var previousShoulderAngle: Double?

    /// 蛇行のランダムウォーク（-1...1 付近）。
    private var driftVelocity: Double = 0

    /// 表示・音づけ用の速度（m/s）。
    private var smoothedSpeed: Double = 0

    // MARK: - 画面からの入力

    func setCanvasSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        canvasSize = size
    }

    /// 触れている指の一覧を受け取り、左右の足に割り当てる。
    ///
    /// 割り当ては指が触れた瞬間の x 座標（画面中央より左か右か）で決め、
    /// 一度決まったら指を離すまで変えない。3本目以降は無視する。
    func updateContacts(_ contacts: [DualThumbTracker.Contact]) {
        let present = Set(contacts.map(\.id))

        // 離れた指を解放する。
        if let id = left.touchID, !present.contains(id) { left = FootState() }
        if let id = right.touchID, !present.contains(id) { right = FootState() }

        let midX = canvasSize.width > 1 ? Double(canvasSize.width) * 0.5 : 0

        for contact in contacts {
            if contact.id == left.touchID {
                left.location = contact.location
                continue
            }
            if contact.id == right.touchID {
                right.location = contact.location
                continue
            }
            // 新しい指。画面中央より左なら左足、右なら右足。埋まっていれば反対側へ回す。
            let prefersLeft = Double(contact.location.x) < midX
            if prefersLeft, left.touchID == nil {
                left = placed(contact)
            } else if !prefersLeft, right.touchID == nil {
                right = placed(contact)
            } else if left.touchID == nil {
                left = placed(contact)
            } else if right.touchID == nil {
                right = placed(contact)
            }
        }
    }

    private func placed(_ contact: DualThumbTracker.Contact) -> FootState {
        var state = FootState()
        state.touchID = contact.id
        state.location = contact.location
        state.previousLocation = contact.location
        return state
    }

    // MARK: - ラウンド進行

    func beginSession() {
        positionX = 0
        positionZ = 0
        heading = 0
        stepCount = 0
        left = FootState()
        right = FootState()
        lastSteppedFoot = .right
        previousShoulderAngle = nil
        driftVelocity = 0
        smoothedSpeed = 0
        phase = .walking
        startRuntime()
    }

    func returnToTitle() {
        stopRuntime()
        phase = .title
        left = FootState()
        right = FootState()
        previousShoulderAngle = nil
        publishDebugSnapshot()
    }

    // MARK: - アプリのライフサイクル

    func handleAppDidBecomeActive() {
        guard phase == .walking else { return }
        startRuntime()
    }

    func handleAppWillResignActive() {
        stopRuntime()
        left = FootState()
        right = FootState()
        previousShoulderAngle = nil
    }

    private func startRuntime() {
        haptics.prepare()
        audio.start()
        audio.updateListener(x: positionX, z: positionZ, headingRadians: heading)
        guard !ticker.isRunning else { return }
        ticker.onTick = { [weak self] dt in
            self?.tick(dt)
        }
        ticker.start()
    }

    private func stopRuntime() {
        ticker.stop()
        ticker.onTick = nil
        audio.stop()
        haptics.shutdown()
    }

    // MARK: - 毎フレームの更新

    private func tick(_ rawDelta: CFTimeInterval) {
        // 画面が詰まったときに巨大な dt が来ると挙動が壊れるので上限を設ける。
        let dt = clamped(Double(rawDelta), 0, 1.0 / 20.0)
        guard canvasSize.height > 1 else { return }

        updateHeadingFromShoulderLine()
        let advance = consumeStrideInput()

        // 前進は指の動きと 1:1 で即座に反映する（平滑化すると足の裏の感じが鈍る）。
        if advance > 0 {
            positionX += sin(heading) * advance
            positionZ += cos(heading) * advance
        }

        let instantaneousSpeed = dt > 0 ? advance / dt : 0
        smoothedSpeed = smoothed(current: smoothedSpeed,
                                 target: instantaneousSpeed,
                                 tau: Tuning.Walk.advanceSmoothing,
                                 dt: dt)

        audio.updateListener(x: positionX, z: positionZ, headingRadians: heading)
        publishDebugSnapshot()
    }

    /// 肩のライン（両親指を結ぶ線）の回転を進行方向へ反映する。
    private func updateHeadingFromShoulderLine() {
        guard left.isDown, right.isDown else {
            // 片方でも浮いたら基準を捨てる。置き直しで勝手に回らないようにするため。
            previousShoulderAngle = nil
            return
        }

        let angle = atan2(Double(right.location.y - left.location.y),
                          Double(right.location.x - left.location.x))

        defer { previousShoulderAngle = angle }
        guard let previous = previousShoulderAngle else { return }

        var delta = angle - previous
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }

        // 指を持ち替えた瞬間は角度が飛ぶので、大きすぎる変化は無視する。
        let threshold = Tuning.Walk.regripAngleThresholdDegrees * .pi / 180
        guard abs(delta) < threshold else { return }

        // 画面の y は下向きが正なので、素の delta は「左親指を下げると左へ曲がる」になる。
        // 歩行の実感（左足を大きく踏み出すと右へ向く）に合わせて符号を反転させておく。
        let sign = Tuning.Walk.invertSteering ? 1.0 : -1.0
        heading += delta * Tuning.Walk.steeringGain * sign
    }

    /// 親指の下方向の動きを歩幅に変換し、このフレームぶんの前進距離（メートル）を返す。
    private func consumeStrideInput() -> Double {
        let strokeUnit = Double(canvasSize.height) * Tuning.Walk.strideStrokeRatio
        guard strokeUnit > 1 else { return 0 }

        var advance: Double = 0
        advance += consumeStride(for: .left, strokeUnit: strokeUnit)
        advance += consumeStride(for: .right, strokeUnit: strokeUnit)
        return advance
    }

    private func consumeStride(for foot: Foot, strokeUnit: Double) -> Double {
        var state = foot == .left ? left : right
        defer {
            if foot == .left { left = state } else { right = state }
        }

        guard state.isDown else { return 0 }

        // 下方向の移動だけが推進力になる。上へ戻す動きは足を前に運び直す動作にあたる。
        let dy = Double(state.location.y - state.previousLocation.y)
        state.previousLocation = state.location
        guard dy > 0 else { return 0 }

        // 交互に踏まないと進まない。遊脚（前回踏んだ足の反対）だけが全力で効く。
        let isSwingFoot = foot == lastSteppedFoot.opposite
        let gain = isSwingFoot ? 1.0 : Tuning.Walk.sameFootGain

        let normalized = (dy / strokeUnit) * gain
        state.strokeProgress += normalized

        // 一歩ぶん踏み切ったら着地。余りは次の一歩に持ち越す。
        if state.strokeProgress >= 1.0 {
            state.strokeProgress -= 1.0
            land(foot: foot)
        }

        return normalized * Tuning.Walk.strideAdvance
    }

    /// 一歩ぶんの着地。
    private func land(foot: Foot) {
        lastSteppedFoot = foot
        stepCount += 1
        applyBlindDrift()
        haptics.playFootstep(isLeft: foot == .left)
        audio.playFootstep(isLeft: foot == .left)
    }

    /// 目を閉じて歩いたときの蛇行。
    ///
    /// 毎歩バラバラに揺らすと単なるノイズになって方向感が失われないので、
    /// 持続性のあるランダムウォーク（AR(1)）にして「しばらく同じ方向へ逸れ続ける」ようにしている。
    private func applyBlindDrift() {
        let persistence = clamped01(Tuning.Walk.blindDriftPersistence)
        let innovation = Double.random(in: -1...1) * (1 - persistence * persistence).squareRoot()
        driftVelocity = driftVelocity * persistence + innovation
        heading += driftVelocity * Tuning.Walk.blindDriftDegreesPerStep * .pi / 180
    }

    // MARK: - デバッグ

    private func publishDebugSnapshot() {
        guard isDebugVisible else { return }

        var snapshot = DebugSnapshot()
        snapshot.positionX = positionX
        snapshot.positionZ = positionZ
        snapshot.headingDegrees = normalizedDegrees(heading * 180 / .pi)
        snapshot.steps = stepCount
        snapshot.leftDown = left.isDown
        snapshot.rightDown = right.isDown
        snapshot.leftProgress = left.strokeProgress
        snapshot.rightProgress = right.strokeProgress
        snapshot.swingFootIsLeft = lastSteppedFoot.opposite == .left
        snapshot.speed = smoothedSpeed
        snapshot.driftDegrees = driftVelocity * Tuning.Walk.blindDriftDegreesPerStep

        let dx = Tuning.Audio.Landmark.position.x - positionX
        let dz = Tuning.Audio.Landmark.position.z - positionZ
        snapshot.landmarkDistance = (dx * dx + dz * dz).squareRoot()
        // 自分の向きから見て、基準音がどちらにあるか（0 = 正面、+ = 右）。
        let absoluteBearing = atan2(dx, dz)
        snapshot.landmarkBearingDegrees = normalizedSignedDegrees((absoluteBearing - heading) * 180 / .pi)

        if snapshot != debug {
            debug = snapshot
        }
    }

    private func normalizedDegrees(_ value: Double) -> Double {
        var d = value.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private func normalizedSignedDegrees(_ value: Double) -> Double {
        var d = normalizedDegrees(value)
        if d > 180 { d -= 360 }
        return d
    }

    /// 3本指タップなどから呼ばれるデバッグ表示トグル。
    func toggleDebug() {
        isDebugVisible.toggle()
        publishDebugSnapshot()
    }

    // MARK: - 動作確認

    /// タイトル画面の「触覚テスト」から呼ばれる。実機で触覚が鳴っているかの確認用。
    /// - Returns: 再生を開始できたら true（シミュレータや非対応端末では false）。
    @discardableResult
    func testHaptics() -> Bool {
        haptics.playSelfTest()
    }
}
