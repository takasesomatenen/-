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
    /// 2本指ダブルタップ（タイトルへ戻る）
    var onTwoFingerDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onThreeFingerTap: onThreeFingerTap, onTwoFingerDoubleTap: onTwoFingerDoubleTap)
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
        context.coordinator.onTwoFingerDoubleTap = onTwoFingerDoubleTap
    }

    static func dismantleUIView(_ uiView: AttachingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: -

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onThreeFingerTap: () -> Void
        var onTwoFingerDoubleTap: () -> Void

        private weak var attachedWindow: UIWindow?
        private var recognizers: [UIGestureRecognizer] = []

        init(onThreeFingerTap: @escaping () -> Void, onTwoFingerDoubleTap: @escaping () -> Void) {
            self.onThreeFingerTap = onThreeFingerTap
            self.onTwoFingerDoubleTap = onTwoFingerDoubleTap
        }

        func attach(to window: UIWindow) {
            guard attachedWindow !== window else { return }
            detach()

            let threeFinger = UITapGestureRecognizer(target: self, action: #selector(handleThreeFinger))
            threeFinger.numberOfTouchesRequired = 3
            threeFinger.numberOfTapsRequired = 1

            let twoFinger = UITapGestureRecognizer(target: self, action: #selector(handleTwoFinger))
            twoFinger.numberOfTouchesRequired = 2
            twoFinger.numberOfTapsRequired = 2

            for recognizer in [threeFinger, twoFinger] {
                // 下の SwiftUI ジェスチャを殺さないための設定。
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
            }

            recognizers = [threeFinger, twoFinger]
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
        @objc private func handleTwoFinger() { onTwoFingerDoubleTap() }

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
