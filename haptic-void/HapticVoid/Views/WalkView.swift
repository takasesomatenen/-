import SwiftUI

/// 歩行本体。通常時は完全な黒。指の座標だけを拾い、フィードバックは触覚と音で返す。
struct WalkView: View {
    @EnvironmentObject private var engine: WalkEngine

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 触覚と音が主役なので、見た目は徹底して何もない。
                Color.black
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 両手の親指を別々に追う層。DragGesture では指を1本しか区別できない。
                DualThumbTracker { contacts in
                    engine.updateContacts(contacts)
                }

                if engine.isDebugVisible {
                    DebugOverlay()
                        .allowsHitTesting(false)
                }
            }
            .onAppear { engine.setCanvasSize(proxy.size) }
            .onChange(of: proxy.size) { _, newSize in
                engine.setCanvasSize(newSize)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}
