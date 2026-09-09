import SwiftUI
import UIKit

/// 画面上の指を、1本ずつ独立に追いかけるビュー。
///
/// SwiftUI の `DragGesture` は指を1本しか区別できないため、
/// 両手の親指を別々の「足」として扱うにはこの層が必要になる。
/// `UITouch` のインスタンスそのものを識別子に使うので、
/// どちらの指が動いたのかをフレームをまたいで追跡できる。
///
/// - Note: 触覚のためにタッチを消費しきってはいけないので、
///   `MultiFingerTapCatcher`（ウインドウ側の隠しジェスチャ）とは競合しない。
///   あちらは `cancelsTouchesInView = false` なので、このビューにも同じタッチが届く。
struct DualThumbTracker: UIViewRepresentable {

    /// 現在触れている指の一覧。指が増減／移動するたびに呼ばれる。
    var onChange: @MainActor ([Contact]) -> Void

    /// 1本の指。`id` は指が触れている間ずっと変わらない。
    struct Contact: Identifiable, Equatable {
        let id: ObjectIdentifier
        var location: CGPoint
    }

    func makeUIView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TrackingView, context: Context) {
        uiView.onChange = onChange
    }

    // MARK: -

    final class TrackingView: UIView {
        var onChange: (@MainActor ([Contact]) -> Void)?

        /// 触れている指を、触れた順に保持する。
        /// `UITouch` は指が離れるまで同一インスタンスであることが保証されている。
        private var active: [UITouch] = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            for touch in touches where !active.contains(touch) {
                active.append(touch)
            }
            publish()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            publish()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            remove(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            remove(touches)
        }

        private func remove(_ touches: Set<UITouch>) {
            active.removeAll { touches.contains($0) }
            publish()
        }

        private func publish() {
            let contacts = active.map {
                Contact(id: ObjectIdentifier($0), location: $0.location(in: self))
            }
            onChange?(contacts)
        }
    }
}
