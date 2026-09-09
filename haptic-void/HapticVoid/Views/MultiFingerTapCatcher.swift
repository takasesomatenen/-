import SwiftUI
import UIKit

/// 複数指タップを拾うための隠しジェスチャ。
///
/// SwiftUI の DragGesture と取り合いにならないよう、
/// 自前のビューではなく **ウインドウ** に UIGestureRecognizer を直接付けている。
/// （`cancelsTouchesInView = false` なので、下の DragGesture は普通に動き続ける）
struct MultiFingerTapCatcher: UIViewRepresentable {

    /// 3本指シングルタップ（デバッグ表示の切り替え）
    var onThreeFingerTap: () -> Void
    /// 4本指タップ（タイトルへ戻る）
    ///
    /// - Note: かつては2本指ダブルタップだったが、両手の親指で歩く操作と衝突する。
    ///   親指を置き直すたびに2本指タップが成立してしまい、
    ///   回頭のために持ち替えるだけでタイトルへ戻されていた。
    ///   遊んでいる間に絶対に起きない本数まで離す必要がある。
    var onFourFingerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onThreeFingerTap: onThreeFingerTap, onFourFingerTap: onFourFingerTap)
    }

    func makeUIView(context: Context) -> AttachingView {
        let view = AttachingView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AttachingView, context: Context) {
        context.coordinator.onThreeFingerTap = onThreeFingerTap
        context.coordinator.onFourFingerTap = onFourFingerTap
    }

    static func dismantleUIView(_ uiView: AttachingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: -

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onThreeFingerTap: () -> Void
        var onFourFingerTap: () -> Void

        private weak var attachedWindow: UIWindow?
        private var recognizers: [UIGestureRecognizer] = []

        init(onThreeFingerTap: @escaping () -> Void, onFourFingerTap: @escaping () -> Void) {
            self.onThreeFingerTap = onThreeFingerTap
            self.onFourFingerTap = onFourFingerTap
        }

        func attach(to window: UIWindow) {
            guard attachedWindow !== window else { return }
            detach()

            let threeFinger = UITapGestureRecognizer(target: self, action: #selector(handleThreeFinger))
            threeFinger.numberOfTouchesRequired = 3
            threeFinger.numberOfTapsRequired = 1

            let fourFinger = UITapGestureRecognizer(target: self, action: #selector(handleFourFinger))
            fourFinger.numberOfTouchesRequired = 4
            fourFinger.numberOfTapsRequired = 1

            for recognizer in [threeFinger, fourFinger] {
                // 下の SwiftUI ジェスチャを殺さないための設定。
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
            }

            recognizers = [threeFinger, fourFinger]
            attachedWindow = window
        }

        func detach() {
            if let window = attachedWindow {
                for recognizer in recognizers {
                    window.removeGestureRecognizer(recognizer)
                }
            }
            recognizers = []
            attachedWindow = nil
        }

        @objc private func handleThreeFinger() { onThreeFingerTap() }
        @objc private func handleFourFinger() { onFourFingerTap() }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// ウインドウに載ったタイミングでジェスチャを取り付けるだけの、見えないビュー。
    final class AttachingView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window = window {
                coordinator?.attach(to: window)
            } else {
                coordinator?.detach()
            }
        }
    }
}
