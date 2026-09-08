import QuartzCore
import UIKit

/// CADisplayLink を薄くラップしたティッカー。
///
/// 指が止まっている間は DragGesture のイベントが飛んでこないが、
/// 平滑化（スムージング）やフェードは動き続ける必要があるため、
/// 触覚・音の更新は画面リフレッシュに同期した固定ティックで回している。
@MainActor
final class DisplayLinkDriver {

    /// CADisplayLink はターゲットを強参照するので、間にプロキシを挟んで循環参照を避ける。
    @MainActor
    private final class Proxy: NSObject {
        weak var owner: DisplayLinkDriver?

        @objc func step(_ link: CADisplayLink) {
            owner?.handle(link)
        }
    }

    /// 経過秒（dt）を受け取るコールバック。
    var onTick: ((CFTimeInterval) -> Void)?

    private let proxy = Proxy()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    init() {
        proxy.owner = self
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let displayLink = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
        // ProMotion 端末では 120Hz まで使う（触覚の追従が滑らかになる）。
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        lastTimestamp = 0
        link = displayLink
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    private func handle(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        // 初回は dt が求まらないので捨てる。
        guard lastTimestamp > 0 else { return }
        onTick?(now - lastTimestamp)
    }
}
