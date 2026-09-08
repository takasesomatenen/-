import CoreGraphics
import Foundation

/// 値を範囲内に丸める。
@inline(__always)
func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}

/// 0...1 に丸める。
@inline(__always)
func clamped01(_ value: Double) -> Double {
    clamped(value, 0, 1)
}

/// 線形補間。
@inline(__always)
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

/// 時定数 `tau`（秒）の指数平滑化を `dt` 秒ぶん進める。
/// フレームレートが揺れても挙動が変わらないよう exp を使っている。
@inline(__always)
func smoothed(current: Double, target: Double, tau: Double, dt: Double) -> Double {
    guard tau > 0.0001 else { return target }
    let k = 1 - exp(-dt / tau)
    return current + (target - current) * k
}

extension CGPoint {
    /// 2点間の距離。
    func distance(to other: CGPoint) -> Double {
        let dx = Double(other.x - x)
        let dy = Double(other.y - y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
