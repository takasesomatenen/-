import CoreGraphics
import Foundation

/// ゲーム全体のチューニングパラメータ。
///
/// 実機で触りながら「数値だけ」を触って調整できるよう、ロジックからは完全に分離してある。
/// すべて `static var` なので、デバッグUIやプレイ中のコードから書き換えても即座に反映される。
enum Tuning {

    // MARK: - 歩行

    /// 両手の親指を交互に下へ払って前進し、両親指を結ぶ線（＝肩のライン）の傾きで向きが変わる。
    enum Walk {
        /// 一歩ぶんの親指ストローク量（画面高さに対する比率）。
        /// 小さくすると小刻みな足踏みに、大きくすると大股でゆったりした歩みになる。
        static var strideStrokeRatio: Double = 0.11

        /// 一歩で前進する距離（メートル）。
        static var strideAdvance: Double = 0.7

        /// 同じ足を続けて使ったときの前進ゲイン。
        /// 1.0 にすると片手だけでスクロールしても普通に進んでしまう（＝歩行感が消える）。
        /// 小さくするほど「左右交互でないと進まない」が強くなる。
        static var sameFootGain: Double = 0.22

        /// 肩のライン（両親指を結ぶ線）の回転を、進行方向の回転へ変換するゲイン。
        /// 1.0 = 1:1（9時→10時の30度で、そのまま30度回頭する）。
        static var steeringGain: Double = 1.0

        /// 回頭の向きを反転させる。実機で「思った向きと逆」ならここを false↔true。
        static var invertSteering: Bool = false

        /// 肩のラインが1フレームでこれ以上動いたら、指の置き直し（再グリップ）とみなして無視する（度）。
        /// 親指を浮かせて持ち替えたときに、その分だけ回頭してしまうのを防ぐ。
        static var regripAngleThresholdDegrees: Double = 25.0

        /// 目を閉じて歩くと人間はまっすぐ歩けない、という現実をそのまま入れる。
        /// 一歩あたりに加わる蛇行の大きさ（度）。0 にすると完全にまっすぐ歩ける。
        static var blindDriftDegreesPerStep: Double = 2.2

        /// 蛇行のランダムウォークの持続性（0...1）。
        /// 大きいほど「同じ方向へ曲がり続けて、じわじわ円を描く」挙動になる。
        /// 小さいと毎歩バラバラに揺れるだけで、方向感を失う感じが出ない。
        static var blindDriftPersistence: Double = 0.88

        /// 前進速度と向きの平滑化時定数（秒）。小さいほど機敏、大きいほどぬるっとする。
        static var advanceSmoothing: Double = 0.06
        static var headingSmoothing: Double = 0.05
    }

    // MARK: - 足音（触覚＋クリック音）

    enum Footstep {
        /// 一歩の触覚の強さと鋭さ。
        static var hapticIntensity: Double = 0.85
        static var hapticSharpness: Double = 0.62

        /// 左右で質感を少しだけ変えると、どちらの足かが触覚だけで分かる。
        /// 右足に対する乗算オフセット（1.0 で左右同じ）。
        static var rightFootIntensityScale: Double = 0.92
        static var rightFootSharpnessOffset: Double = -0.10

        /// クリック音の中心周波数（Hz）と減衰時定数（秒）。
        /// 低く・短くするほど「コツッ」、高く・長くするほど「カツン」に寄る。
        static var clickFrequency: Double = 220.0
        static var clickDecay: Double = 0.045
        /// 音の芯に混ぜるノイズの量（0...1）。硬さ・素材感を決める。
        static var clickNoiseMix: Double = 0.55
        static var clickLevel: Double = 0.5

        /// 足音の左右への振り分け（0 = 中央、1 = 完全に左右）。
        static var clickPan: Double = 0.35
    }

    // MARK: - 触覚エンジン

    enum Haptics {
        /// パターンに埋め込む基準シャープネス。
        /// Core Haptics の `hapticSharpnessControl` は「相対オフセット」なので、
        /// ここを中央値(0.5)にしておくと上下どちらにも振れる。
        static var baseSharpness: Double = 0.5

        /// 方向が分からないとき（静止時）のシャープネス。
        static var neutralSharpness: Double = 0.5

        /// このしきい値以下の変化ならパラメータ送信を省略する（無駄な送信を減らす）。
        static var parameterEpsilon: Double = 0.004
    }

    // MARK: - 音

    enum Audio {
        /// 音を鳴らすかどうか。触覚だけの体験を試したいときは false に。
        static var enabled: Bool = true

        /// 出力全体のマスターボリューム。
        static var masterVolume: Float = 0.9

        /// 遠くで鳴り続ける方角の基準音（landmark）。
        /// これが無いと、自分がどれだけ回ったのかが音から読めない。
        enum Landmark {
            static var enabled: Bool = true
            /// 基準音の位置（メートル）。x = 東、z = 北。
            static var position: (x: Double, z: Double) = (0, 18)
            /// 基準音の高さ（メートル）。少し上に置くと頭外に定位しやすい。
            static var height: Double = 1.2
            /// 音量（0...1）。
            static var level: Float = 0.55
            /// 基準音のピッチ（Hz）と、うなりを作るデチューン比。
            static var frequency: Double = 92.5
            static var detuneRatio: Double = 1.004
            /// ゆっくりした音量ゆらぎ。
            static var lfoFrequency: Double = 0.09
            static var lfoDepth: Double = 0.22
            /// この距離（メートル）から先は減衰しきる。
            static var referenceDistance: Double = 3.0
            static var maximumDistance: Double = 60.0
        }
    }

    // MARK: - デバッグ

    enum Debug {
        /// 起動時からデバッグ表示をONにしておくか。
        static var startVisible: Bool = false
    }
}
