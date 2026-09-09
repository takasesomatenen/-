import SwiftUI

/// 最低限のタイトル画面。本体は真っ黒な歩行画面なので、ここは静かに始めるための入り口。
struct TitleView: View {
    @EnvironmentObject private var engine: WalkEngine

    /// 触覚テストの結果表示（数秒で消える）。
    @State private var hapticTestNote: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("VOID")
                    .font(.system(size: 46, weight: .ultraLight, design: .rounded))
                    .tracking(18)
                    .foregroundStyle(.white.opacity(0.9))
                    // 隠しスイッチ: タイトルを長押しでデバッグ表示を切り替える。
                    .onLongPressGesture(minimumDuration: 1.2) {
                        engine.toggleDebug()
                    }

                Text("見えない場所を、歩いて探す")
                    .font(.system(size: 14, weight: .light, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                instruction("両手の親指が、あなたの両足です。")
                instruction("交互に下へ払うと、一歩ずつ進みます。")
                instruction("片方の親指を止めると、カチッと鳴って舵になります。")
                instruction("そのまま反対の親指を動かすと、動かした角度だけ向きが変わります。")
                instruction("遠くで鳴っている音が、方角の手がかりです。")
                instruction("まっすぐ歩いているつもりでも、少しずつ逸れます。")
                instruction("できれば目を閉じて。失敗はありません。")
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer()

            Button {
                engine.beginSession()
            } label: {
                Text("歩きだす")
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                let started = engine.testHaptics()
                hapticTestNote = started
                    ? "触覚テストを再生中…"
                    : (engine.statusMessage ?? "触覚を再生できませんでした")
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    hapticTestNote = nil
                }
            } label: {
                Text("触覚テスト")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            VStack(spacing: 6) {
                if let hapticTestNote {
                    Text(hapticTestNote)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text("ヘッドホンを着けてください（方角は音の定位で伝えています）")
                Text("2本指ダブルタップでタイトルへ / 3本指タップでデバッグ表示")
                if !engine.supportsHaptics {
                    Text("⚠︎ この端末では触覚が再生されません（音のみで動作します）")
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }
            .font(.system(size: 11, weight: .light, design: .rounded))
            .foregroundStyle(.white.opacity(0.28))
            .multilineTextAlignment(.center)
            .padding(.top, 28)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .light, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
            .fixedSize(horizontal: false, vertical: true)
    }
}
