import SwiftUI

@main
struct HapticVoidApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = ExplorationEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Core Haptics も AVAudioEngine もバックグラウンドでは動かないので、
            // 明示的に止めて、戻ってきたら組み立て直す。
            switch newPhase {
            case .active:
                engine.handleAppDidBecomeActive()
            case .inactive, .background:
                engine.handleAppWillResignActive()
            @unknown default:
                break
            }
        }
    }
}
