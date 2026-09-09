import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

/// 歩行体験の中枢。
///
/// 入力モデル:
/// - **前進**: 左右の親指を交互に下へ払う。下方向の動きだけが推進力になる（上へ戻す動作は足を運び直す動作）。
///   同じ足を続けて使うとゲインが落ちるので、左右交互でないと前へ進まない。
/// - **回頭**: 片方の親指を**止めたまま**にすると回頭モードに入り、そこからは両親指とも舵になる。
///   両親指を結ぶ線＝肩のラインが回った角度ぶん、進行方向も回る。
///   モードの間は前進しないので、回すために親指を下げても歩き出さない。
///   指を離すと歩行に戻る。
///   歩いている間は肩のラインが傾いても向きは一切変わらないので、ただ歩けばまっすぐ進む。
/// - **蛇行**: 目を閉じて歩くと人間はまっすぐ歩けない。これを一歩ごとのランダムウォークとして入れてある。
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
        var beaconBearingDegrees: Double = 0
        var beaconDistance: Double = 0
        var spaceRadius: Double = 0
        var isRotating: Bool = false
        var turnRateDegrees: Double = 0
    }

    // MARK: - 公開状態

    @Published private(set) var phase: Phase = .title
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var debug = DebugSnapshot()
    /// 歩いた軌跡（x = 東, y = 北。メートル）。デバッグマップの描画用。
    @Published private(set) var trail: [CGPoint] = []
    /// いま歩いている洞窟。デバッグマップの描画用。
    @Published private(set) var cave = CaveSpace()
    /// 基準音の位置（x = 東, y = 北）。デバッグマップの描画用。
    @Published private(set) var beaconPositions: [CGPoint] = []
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
    /// 進行方向（ラジアン）。0 = 北、時計回りが正。ラップさせずに保持する。
    private var heading: Double = 0

    /// 足ごとの状態。
    private struct FootState {
        var touchID: ObjectIdentifier?
        var location: CGPoint = .zero
        var previousLocation: CGPoint = .zero
        var strokeProgress: Double = 0
        /// このフレームの移動量。回頭判定と歩幅の両方で使う。
        var frameDelta: CGVector = .zero
        var isDown: Bool { touchID != nil }
    }
    private var left = FootState()
    private var right = FootState()

    /// 直前に着地した足。次に踏むべき足（遊脚）はこの反対側。
    private var lastSteppedFoot: Foot = .right

    /// 肩のラインの前フレームの角度。両親指が乗っていないときは nil。
    private var previousShoulderAngle: Double?

    /// このフレームの**意図的な**回頭量（ラジアン）。蛇行ぶんは含めない。
    private var steeringDelta: Double = 0
    private var smoothedTurnRate: Double = 0

    /// 蛇行のランダムウォーク（-1...1 付近）。
    private var driftVelocity: Double = 0

    /// 表示・音づけ用の速度（m/s）。
    private var smoothedSpeed: Double = 0

    /// 各足が静止し続けている時間（秒）。片方が一定時間止まると回頭モードに入る。
    private var leftStillTime: Double = 0
    private var rightStillTime: Double = 0
    /// 回頭モード。この間は前進せず、肩のラインの回転だけが向きに効く。
    private var isPivoting = false

    /// いまいる場所の広さ（メートル）。残響に連動する。
    private var smoothedSpaceRadius: Double = Tuning.Cave.outsideRadius

    /// 洞窟の中に置いた基準音。
    private var placedBeacons: [Tuning.Audio.Beacon] = []

    /// 軌跡を1点打つ最小間隔（メートル）と、保持する最大点数。
    private let trailSpacing: Double = 0.2
    private let trailCapacity: Int = 600

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
        steeringDelta = 0
        smoothedTurnRate = 0
        driftVelocity = 0
        smoothedSpeed = 0
        leftStillTime = 0
        rightStillTime = 0
        isPivoting = false
        trail = [CGPoint(x: 0, y: 0)]

        buildWorld()
        smoothedSpaceRadius = cave.openness(at: .zero)

        phase = .walking
        startRuntime()
    }

    func returnToTitle() {
        stopRuntime()
        phase = .title
        left = FootState()
        right = FootState()
        previousShoulderAngle = nil
        isPivoting = false
        publishDebugSnapshot()
    }

    /// 洞窟を作り、その部屋の中に基準音を置く。
    private func buildWorld() {
        var generator = SystemRandomNumberGenerator()
        cave = CaveSpace.generate(using: &generator)

        let templates = Tuning.Audio.Space.beacons
        guard !templates.isEmpty else {
            placedBeacons = []
            beaconPositions = []
            return
        }

        placedBeacons = templates.enumerated().map { index, template in
            var beacon = template
            // 出発点の部屋（0番）は避け、離れた部屋へ散らす。
            if cave.chambers.count > 1 {
                let stride = max(1, (cave.chambers.count - 1) / templates.count)
                let chamberIndex = min(cave.chambers.count - 1, 1 + index * stride)
                if let point = cave.placement(inChamber: chamberIndex, using: &generator) {
                    beacon.x = Double(point.x)
                    beacon.z = Double(point.y)
                    return beacon
                }
            }
            // 洞窟が無いときは、出発点を囲むように等間隔で置く。
            let angle = (Double(index) / Double(templates.count)) * 2 * .pi
            beacon.x = sin(angle) * 12
            beacon.z = cos(angle) * 12
            return beacon
        }
        beaconPositions = placedBeacons.map { CGPoint(x: $0.x, y: $0.z) }
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
        isPivoting = false
    }

    private func startRuntime() {
        haptics.prepare()
        audio.start(beacons: placedBeacons)
        audio.updateListener(x: positionX, z: positionZ, headingRadians: heading)
        audio.updateSpace(radius: smoothedSpaceRadius)
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
        guard canvasSize.height > 1, dt > 0 else { return }

        steeringDelta = 0
        sampleFootDeltas()
        updatePivotMode(dt: dt)
        updateHeadingFromShoulderLine(dt: dt)
        // 回頭モードの間は前進しない。舵を切るために親指を下げても歩き出さないようにするため。
        let advance = isPivoting ? 0 : consumeStrideInput()

        // 前進は指の動きと 1:1 で即座に反映する（平滑化すると足の裏の感じが鈍る）。
        if advance > 0 {
            positionX += sin(heading) * advance
            positionZ += cos(heading) * advance
            recordTrail()
        }

        smoothedSpeed = smoothed(current: smoothedSpeed,
                                 target: advance / dt,
                                 tau: Tuning.Walk.advanceSmoothing,
                                 dt: dt)

        updateRotationCue(dt: dt)
        updateSpace(dt: dt)

        audio.updateListener(x: positionX, z: positionZ, headingRadians: heading)
        audio.updateFades(dt: dt)
        publishDebugSnapshot()
    }

    /// 各足のこのフレームの移動量を確定させる。
    private func sampleFootDeltas() {
        func sample(_ state: inout FootState) {
            guard state.isDown else {
                state.frameDelta = .zero
                return
            }
            state.frameDelta = CGVector(dx: state.location.x - state.previousLocation.x,
                                        dy: state.location.y - state.previousLocation.y)
            state.previousLocation = state.location
        }
        sample(&left)
        sample(&right)
    }

    /// 回頭モードの出入りを判定する。
    ///
    /// 歩行と回頭は、肩のラインの動きとしては原理的に区別できない。
    /// 交互に払う動作はそれ自体が肩のラインの回転そのものだからで、
    /// 「下方向なら歩行」のように信号側で切り分けようとすると必ず破綻する。
    /// （下方向だけ回頭を止めると、足を戻す上方向のぶんが打ち消されずに残って一歩ごとに曲がる）
    ///
    /// なので **片方をホールドする** という明示的な操作でモードを分ける。
    /// 入った合図は Zippo の音で返るので、目を閉じていてもモードが分かる。
    private func updatePivotMode(dt: Double) {
        let speedLeft = speed(of: left, dt: dt)
        let speedRight = speed(of: right, dt: dt)

        // 指が乗っていない間は静止時間を溜めない。
        // 溜めてしまうと、指を置いた瞬間に回頭モードへ入って歩き出しの一歩が食われる。
        leftStillTime = left.isDown && speedLeft < Tuning.Walk.pivotStillSpeed ? leftStillTime + dt : 0
        rightStillTime = right.isDown && speedRight < Tuning.Walk.pivotStillSpeed ? rightStillTime + dt : 0

        // 指を離したら歩行に戻る。
        // 速度で抜けるようにすると「片方を下、片方を上」で回したときに
        // 途中でモードが切れて、効いたり効かなかったりする。
        guard left.isDown, right.isDown else {
            if isPivoting { endPivot() }
            return
        }
        guard !isPivoting else { return }

        // どちらかを止め続けたら舵に持ち替える。以後は両親指とも舵になる。
        if max(leftStillTime, rightStillTime) >= Tuning.Walk.pivotHoldTime {
            beginPivot()
        }
    }

    private func speed(of state: FootState, dt: Double) -> Double {
        guard state.isDown, dt > 0 else { return 0 }
        return hypot(Double(state.frameDelta.dx), Double(state.frameDelta.dy)) / dt
    }

    private func beginPivot() {
        isPivoting = true
        // 回り始めた瞬間の正面に音源を置く。以後この点は動かないので、
        // 体が回るぶんだけ音が横へ流れる＝回転そのものが聴こえる。
        let x = positionX + sin(heading) * Tuning.Rotation.distance
        let z = positionZ + cos(heading) * Tuning.Rotation.distance
        audio.beginRotationCue(x: x, z: z)
    }

    private func endPivot() {
        isPivoting = false
        audio.endRotationCue()
    }

    /// 肩のライン（両親指を結ぶ線）の回転を進行方向へ反映する。
    ///
    /// **回頭モードのときだけ**効く。歩行中に肩のラインが傾いても向きは変えない。
    /// こうしないと、左右の歩幅がわずかに違うだけで、まっすぐ歩いているつもりでも曲がってしまう。
    private func updateHeadingFromShoulderLine(dt: Double) {
        guard left.isDown, right.isDown else {
            // 片方でも浮いたら基準を捨てる。置き直しで勝手に回らないようにするため。
            previousShoulderAngle = nil
            return
        }

        let angle = atan2(Double(right.location.y - left.location.y),
                          Double(right.location.x - left.location.x))

        // 回頭しない場合でも基準は更新する。次に回し始めたときに角度が飛ばないように。
        defer { previousShoulderAngle = angle }
        guard let previous = previousShoulderAngle, isPivoting else { return }

        var delta = angle - previous
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }

        // 指を持ち替えた瞬間は角度が飛ぶので、大きすぎる変化は無視する。
        let threshold = Tuning.Walk.regripAngleThresholdDegrees * .pi / 180
        guard abs(delta) < threshold else { return }

        // 指の微細な揺れで回らないための不感帯。
        // **角速度**で判定する（フレームあたりで見ると、ゆっくり回したときに丸ごと捨ててしまう）。
        let deadzoneRate = Tuning.Walk.steeringDeadzoneDegreesPerSecond * .pi / 180
        guard abs(delta) / dt > deadzoneRate else { return }

        // 画面の y は下向きが正なので、素の delta は「左親指を下げると左へ曲がる」になる。
        // 歩行の実感（左足を大きく踏み出すと右へ向く）に合わせて符号を反転させておく。
        let sign = Tuning.Walk.invertSteering ? 1.0 : -1.0
        steeringDelta = delta * Tuning.Walk.steeringGain * sign
        heading += steeringDelta
    }

    /// 親指の下方向の動きを歩幅に変換し、このフレームぶんの前進距離（メートル）を返す。
    private func consumeStrideInput() -> Double {
        let strokeUnit = Double(canvasSize.height) * Tuning.Walk.strideStrokeRatio
        guard strokeUnit > 1 else { return 0 }
        return consumeStride(for: .left, strokeUnit: strokeUnit)
             + consumeStride(for: .right, strokeUnit: strokeUnit)
    }

    private func consumeStride(for foot: Foot, strokeUnit: Double) -> Double {
        var state = foot == .left ? left : right
        defer {
            if foot == .left { left = state } else { right = state }
        }

        guard state.isDown else { return 0 }

        // 下方向の移動だけが推進力になる。上へ戻す動きは足を前に運び直す動作にあたる。
        let dy = Double(state.frameDelta.dy)
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
    /// 毎歩バラバラに揺らすと単なるノイズになって方向感が失われるので、
    /// 持続性のあるランダムウォーク（AR(1)）にして「しばらく同じ方向へ逸れ続ける」ようにしている。
    ///
    /// - Note: これは意図的な回頭ではないので `steeringDelta` には積まない。
    ///   積むと、蛇行のたびに回頭フィードバック音が誤発火する。
    private func applyBlindDrift() {
        let persistence = clamped01(Tuning.Walk.blindDriftPersistence)
        let innovation = Double.random(in: -1...1) * (1 - persistence * persistence).squareRoot()
        driftVelocity = driftVelocity * persistence + innovation
        heading += driftVelocity * Tuning.Walk.blindDriftDegreesPerStep * .pi / 180
    }

    // MARK: - 回頭のフィードバック

    /// 表示用の角速度を追従させる。
    /// 回頭フィードバック音の出し入れ自体は、モードの出入り（`beginPivot` / `endPivot`）で行う。
    private func updateRotationCue(dt: Double) {
        smoothedTurnRate = smoothed(current: smoothedTurnRate,
                                    target: steeringDelta / dt,
                                    tau: 0.08,
                                    dt: dt)
    }

    // MARK: - 空間の広さ

    /// いまいる場所の広さを求め、残響へ渡す。
    private func updateSpace(dt: Double) {
        let raw = cave.openness(at: CGPoint(x: positionX, y: positionZ))
        smoothedSpaceRadius = smoothed(current: smoothedSpaceRadius,
                                       target: raw,
                                       tau: Tuning.Cave.spaceSmoothing,
                                       dt: dt)
        audio.updateSpace(radius: smoothedSpaceRadius)
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
        snapshot.spaceRadius = smoothedSpaceRadius
        snapshot.isRotating = isPivoting
        snapshot.turnRateDegrees = smoothedTurnRate * 180 / .pi

        // いちばん近い基準音との関係を出す。
        if let nearest = nearestBeacon() {
            let dx = nearest.x - positionX
            let dz = nearest.z - positionZ
            snapshot.beaconDistance = (dx * dx + dz * dz).squareRoot()
            // 自分の向きから見て、その音がどちらにあるか（0 = 正面、+ = 右）。
            let absoluteBearing = atan2(dx, dz)
            snapshot.beaconBearingDegrees = normalizedSignedDegrees((absoluteBearing - heading) * 180 / .pi)
        }

        if snapshot != debug {
            debug = snapshot
        }
    }

    /// 現在地を軌跡に打つ。一定距離動いたときだけ点を増やす。
    private func recordTrail() {
        let point = CGPoint(x: positionX, y: positionZ)
        if let last = trail.last {
            let dx = Double(point.x - last.x)
            let dy = Double(point.y - last.y)
            guard (dx * dx + dy * dy).squareRoot() >= trailSpacing else { return }
        }
        trail.append(point)
        if trail.count > trailCapacity {
            trail.removeFirst(trail.count - trailCapacity)
        }
    }

    private func nearestBeacon() -> Tuning.Audio.Beacon? {
        placedBeacons.min { a, b in
            let da = (a.x - positionX) * (a.x - positionX) + (a.z - positionZ) * (a.z - positionZ)
            let db = (b.x - positionX) * (b.x - positionX) + (b.z - positionZ) * (b.z - positionZ)
            return da < db
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
