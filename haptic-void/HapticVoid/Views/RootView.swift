import SwiftUI
import UIKit

/// タイトルと探索画面を切り替えるだけの器。
/// 隠しジェスチャ（3本指タップ／2本指ダブルタップ）はここで常時受け付ける。
struct RootView: View {
    @EnvironmentObject private var engine: ExplorationEngine

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch engine.phase {
            case .title:
                TitleView()
                    .transition(.opacity)
            case .exploring, .arrived:
                ExplorationView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: engine.phase)
        .background(
            MultiFingerTapCatcher(
                onThreeFingerTap: { engine.toggleDebug() },
                onTwoFingerDoubleTap: { engine.returnToTitle() }
            )
            .frame(width: 0, height: 0)
        )
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // 目を閉じて探索している間に画面が落ちないようにする。
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
