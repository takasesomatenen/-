import CoreGraphics
import Foundation

/// 広い部屋と狭い通路がつながった、洞窟のような空間。
///
/// 壁として当たり判定は持たない。**いまいる場所がどれくらい広いか**を返すだけの層で、
/// その広さが残響の大きさになる。狭い通路を抜けて広間に出た瞬間に響きが開く、
/// という体験を作るためのもの。
struct CaveSpace {

    struct Chamber: Equatable {
        var center: CGPoint
        var radius: Double
    }

    struct Corridor: Equatable {
        var a: CGPoint
        var b: CGPoint
        var radius: Double
    }

    var chambers: [Chamber] = []
    var corridors: [Corridor] = []

    /// 部屋を数珠つなぎにしたランダムな洞窟を作る。
    ///
    /// 最初の部屋は必ず原点（プレイヤーの出発点）に置く。
    /// 進む方向は前回の方向から大きく外れないようにしてあるので、
    /// 折り返しの多い団子状ではなく、伸びていく洞窟になる。
    static func generate(using generator: inout some RandomNumberGenerator) -> CaveSpace {
        var cave = CaveSpace()
        guard Tuning.Cave.enabled, Tuning.Cave.chamberCount > 0 else { return cave }

        var center = CGPoint.zero
        var direction = Double.random(in: 0..<(2 * .pi), using: &generator)

        cave.chambers.append(
            Chamber(center: center,
                    radius: Double.random(in: Tuning.Cave.chamberRadiusRange, using: &generator))
        )

        for _ in 1..<Tuning.Cave.chamberCount {
            // 進行方向を少しずつ曲げていく（±70度）。
            direction += Double.random(in: -1.22...1.22, using: &generator)
            let spacing = Double.random(in: Tuning.Cave.chamberSpacingRange, using: &generator)
            let next = CGPoint(x: center.x + CGFloat(cos(direction) * spacing),
                               y: center.y + CGFloat(sin(direction) * spacing))
            let radius = Double.random(in: Tuning.Cave.chamberRadiusRange, using: &generator)

            cave.corridors.append(
                Corridor(a: center, b: next,
                         radius: Double.random(in: Tuning.Cave.corridorRadiusRange, using: &generator))
            )
            cave.chambers.append(Chamber(center: next, radius: radius))
            center = next
        }
        return cave
    }

    /// その地点の「広さ」（メートル）。
    ///
    /// 部屋や通路に含まれていればその半径を返し、複数に重なっていれば広いほうを採る。
    /// どこにも含まれていなければ岩の中とみなして最小値を返す。
    /// 境目で残響が階段状に変わらないよう、縁に近づくほど値がなだらかに落ちる。
    func openness(at point: CGPoint) -> Double {
        var best = Tuning.Cave.outsideRadius

        for chamber in chambers {
            let d = point.distance(to: chamber.center)
            guard d < chamber.radius else { continue }
            // 縁では 60% まで落として、通路へ滑らかにつなぐ。
            let edge = 1.0 - 0.4 * clamped01(d / chamber.radius)
            best = max(best, chamber.radius * edge)
        }

        for corridor in corridors {
            let d = CaveSpace.distance(from: point, toSegment: corridor.a, corridor.b)
            guard d < corridor.radius else { continue }
            best = max(best, corridor.radius)
        }
        return best
    }

    /// 部屋の中のどこか（中心寄り）。基準音を置くのに使う。
    func placement(inChamber index: Int,
                   using generator: inout some RandomNumberGenerator) -> CGPoint? {
        guard chambers.indices.contains(index) else { return nil }
        let chamber = chambers[index]
        let angle = Double.random(in: 0..<(2 * .pi), using: &generator)
        let radius = chamber.radius * Double.random(in: 0...0.5, using: &generator)
        return CGPoint(x: chamber.center.x + CGFloat(cos(angle) * radius),
                       y: chamber.center.y + CGFloat(sin(angle) * radius))
    }

    /// 点と線分の距離。
    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let abx = Double(b.x - a.x), aby = Double(b.y - a.y)
        let apx = Double(point.x - a.x), apy = Double(point.y - a.y)
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0.0001 else { return point.distance(to: a) }
        let t = clamped01((apx * abx + apy * aby) / lengthSquared)
        let closest = CGPoint(x: a.x + CGFloat(abx * t), y: a.y + CGFloat(aby * t))
        return point.distance(to: closest)
    }
}
