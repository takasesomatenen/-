import SwiftUI

/// 探索本体。通常時は完全な黒。指の座標だけを拾い、フィードバックは触覚と音で返す。
struct ExplorationView: View {
    @EnvironmentObject private var engine: ExplorationEngine

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 触覚が主役なので、見た目は徹底して何もない。
                Color.black
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        // 指の座標取得は要件どおり DragGesture で行う。
                        // minimumDistance: 0 にすることで「置いただけ」でも座標が取れる。
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                engine.updateTouch(value.location)
                            }
                            .onEnded { _ in
                                engine.endTouch()
                            }
                    )

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
