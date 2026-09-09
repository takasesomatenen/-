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

    // MARK: - 足音

    enum Footstep {
        /// 一歩の触覚の強さと鋭さ。
        static var hapticIntensity: Double = 0.85
        static var hapticSharpness: Double = 0.62

        /// 左右で質感を少しだけ変えると、どちらの足かが触覚だけでも分かる。
        /// 右足に対する乗算オフセット（1.0 で左右同じ）。
        static var rightFootIntensityScale: Double = 0.92
        static var rightFootSharpnessOffset: Double = -0.10

        /// 足音サンプルの音量。
        static var level: Float = 0.9

        /// 足音の左右への振り分け（0 = 中央、1 = 完全に左右）。
        /// 自分の足元の音なので定位はさせず、パンだけで左右を示す。
        static var pan: Float = 0.3

        /// 一歩ごとの音量のばらつき（0 で完全に均一）。
        /// 同じ波形の連打は機械的に聴こえるので、わずかに散らす。
        static var levelVariation: Double = 0.14
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

        /// 空間に置く方角の基準音。
        ///
        /// 1つだけだと「動いた」しか分からない。複数あって初めて、
        /// 星座が回るように自分が何度回ったのかが読める。
        struct Beacon {
            /// 位置（メートル）。x = 東、z = 北。
            var x: Double
            var z: Double
            /// 高さ（メートル）。耳の高さから少しずらすと頭外に定位しやすい。
            var height: Double = 1.4
            /// 基音（Hz）。
            ///
            /// - Important: 低い純音は人間が最も定位できない信号（ITD しか手がかりが無く、
            ///   前後の取り違えも起きやすい）。倍音が 1〜3kHz に届く高さにして、
            ///   ILD とスペクトル手がかりが効く帯域にエネルギーを置くこと。
            var frequency: Double
            /// 脈打つ周期（秒）。**アタックのある音でないと定位は立たない。**
            /// 音源ごとに変えると、複数あっても聴き分けられる。
            var pulseInterval: Double
            /// 脈の減衰時定数（秒）。
            var pulseDecay: Double = 0.55
            /// 脈と脈の間を埋める持続音の量（0...1）。手がかりが途切れないように少しだけ入れる。
            var bedLevel: Double = 0.18
            var level: Float = 0.8
        }

        enum Space {
            static var enabled: Bool = true

            /// 方角の基準音。バラけた方向・高さ・音色にしておくと回頭が読みやすい。
            static var beacons: [Beacon] = [
                Beacon(x:   0, z:  12, height: 1.5, frequency: 294.0, pulseInterval: 1.7),
                Beacon(x:  10, z:  -5, height: 1.1, frequency: 392.0, pulseInterval: 2.3),
                Beacon(x:  -9, z:   2, height: 1.8, frequency: 233.0, pulseInterval: 2.9)
            ]

            /// この距離（メートル）から先は減衰しきる。
            static var referenceDistance: Double = 4.0
            static var maximumDistance: Double = 60.0

            /// わずかな残響。頭の中ではなく「外」で鳴っている感じ（頭外定位）が出て、
            /// 方向が格段に読みやすくなる。入れすぎると定位が滲むので控えめに。
            static var reverbEnabled: Bool = true
            static var reverbLevelDB: Float = -10.0
            static var reverbBlend: Float = 0.22
        }
    }

    // MARK: - デバッグ

    enum Debug {
        /// 起動時からデバッグ表示をONにしておくか。
        static var startVisible: Bool = false
    }
}
