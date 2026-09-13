import CoreGraphics
import Foundation

/// 指で円を描いたことを検出する。
///
/// 3つの条件をすべて満たしたときだけ成立させる:
/// 1. **経路の接線が一周ぶん回っている**（進行方向の変化の総和）
/// 2. **囲んだ面積がある**（符号付き面積）
/// 3. **描き始めの近くに戻ってきている**
///
/// 1だけでは、指を往復させたときに折り返しで接線が180度回るので、
/// 2往復で一周ぶん積み上がって誤検出する。往復は面積を囲まないので、2がそれを弾く。
/// 3が無いと、大きく曲がりながら遠くへ流れていく動きも円とみなされる。
///
/// 重心からの方位角を積む方式は採らなかった。描き始めは重心が弧の上に乗っていて
/// 半径が立たず、その間ぶんを取りこぼして一周に届かない。
struct CircleGestureDetector {

    private var lastPoint: CGPoint?
    private var startPoint: CGPoint?
    private var previousDirection: Double?
    private var accumulatedTurn: Double = 0
    private var signedArea: Double = 0
    private var age: Double = 0
    private var idleTime: Double = 0

    /// 経路がどれだけ回ったか（度）。
    /// 歩行の推進を抑えるのにも使う（円を描いている最中に前へ進んでしまわないように）。
    var turnedDegrees: Double { abs(accumulatedTurn) * 180 / .pi }

    /// 円を描いている途中とみなせるか。
    var isDrawing: Bool {
        turnedDegrees >= Tuning.Fire.drawingSuppressDegrees
            && abs(signedArea) >= Tuning.Fire.circleMinArea * 0.25
    }

    mutating func reset() {
        lastPoint = nil
        startPoint = nil
        previousDirection = nil
        accumulatedTurn = 0
        signedArea = 0
        age = 0
        idleTime = 0
    }

    /// - Parameter point: いま触れている指の位置。指が無いときは nil。
    /// - Returns: 円が閉じたら true。
    mutating func update(point: CGPoint?, dt: Double) -> Bool {
        guard let point else {
            reset()
            return false
        }

        guard let last = lastPoint else {
            lastPoint = point
            startPoint = point
            return false
        }

        // 指が止まっている間は何も積まない。長く止まったら描くのをやめたとみなす。
        let travelled = last.distance(to: point)
        guard travelled >= Tuning.Fire.circleSampleSpacing else {
            idleTime += dt
            if idleTime > Tuning.Fire.circleIdleTimeout { reset() }
            return false
        }
        idleTime = 0

        age += dt
        if age > Tuning.Fire.circleWindow {
            // 描くのが遅すぎて一周に至らなかった。いまの点から積み直す。
            reset()
            lastPoint = point
            startPoint = point
            return false
        }

        let direction = atan2(Double(point.y - last.y), Double(point.x - last.x))
        if let previous = previousDirection {
            var delta = direction - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            // 鋭すぎる折れは手の震えか取りこぼし。円の一部ではない。
            if abs(delta) < .pi / 2 {
                accumulatedTurn += delta
            }
        }
        previousDirection = direction

        // 描き始めを原点とした符号付き面積（靴ひもの公式）。往復運動では相殺されて0に近づく。
        if let start = startPoint {
            let ax = Double(last.x - start.x), ay = Double(last.y - start.y)
            let bx = Double(point.x - start.x), by = Double(point.y - start.y)
            signedArea += 0.5 * (ax * by - bx * ay)
        }
        lastPoint = point

        let closed = startPoint.map { point.distance(to: $0) <= Tuning.Fire.circleClosureDistance } ?? false
        if abs(accumulatedTurn) >= Tuning.Fire.circleTurnDegrees * .pi / 180,
           abs(signedArea) >= Tuning.Fire.circleMinArea,
           closed {
            reset()
            return true
        }
        return false
    }
}
