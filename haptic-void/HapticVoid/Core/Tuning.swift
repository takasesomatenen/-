import CoreGraphics
import Foundation

/// ゲーム全体のチューニングパラメータ。
///
/// 実機で触りながら「数値だけ」を触って調整できるよう、ロジックからは完全に分離してある。
/// すべて `static var` なので、デバッグUIやプレイ中のコードから書き換えても即座に反映される。
enum Tuning {

    // MARK: - 歩行

    /// 両手の親指を交互に下へ払って前進する。
    /// 曲がるのは「片方を軸にして、もう片方を動かしたとき」だけ。
    /// ただ交互に払っているだけでは曲がらない（歩幅の左右差で勝手に逸れないようにするため）。
    enum Walk {
        /// 一歩ぶんの親指ストローク量（画面高さに対する比率）。
        /// 小さくすると小刻みな足踏みに、大きくすると大股でゆったりした歩みになる。
        static var strideStrokeRatio: Double = 0.11

        /// 一歩で前進する距離（メートル）。
        static var strideAdvance: Double = 0.7

        /// 同じ足を続けて使ったときの前進ゲイン。
        /// 1.0 にすると片手だけでスクロールしても普通に進んでしまう（＝歩行感が消える）。
        static var sameFootGain: Double = 0.22

        /// 肩のライン（両親指を結ぶ線）の回転を、進行方向の回転へ変換するゲイン。
        /// 1.0 = 1:1（9時→10時の30度で、そのまま30度回頭する）。
        static var steeringGain: Double = 1.0

        /// 回頭の向きを反転させる。実機で「思った向きと逆」ならここを false↔true。
        static var invertSteering: Bool = false

        /// 回頭モードに入るまで、片方の親指を静止させておく時間（秒）。
        ///
        /// **片方をホールドすると回頭モードに入り、そこからは両親指とも舵になる。**
        /// このモードの間は前進しない（踏み込んでも進まない）ので、
        /// 回すために親指を下げても勝手に歩き出さない。
        /// 抜けるのは指を離したときだけ。速度で抜けるようにすると、
        /// 「片方を下、片方を上」で回したときに途中でモードが切れて効いたり効かなかったりする。
        ///
        /// 歩行と回頭は、肩のラインの動きとしては見分けがつかない。
        /// 交互に払う動作はそれ自体が肩のラインの回転そのものなので、
        /// 「下方向だから歩行」「上方向だから回頭」のような信号側の切り分けは必ず破綻する。
        /// ホールドという明示的な操作でモードを分けるのがいちばん確実だった。
        ///
        /// モードに入った合図は Zippo の音で返る。
        static var pivotHoldTime: Double = 0.4

        /// 静止とみなす親指の速度（ポイント/秒）。
        static var pivotStillSpeed: Double = 60

        /// 指の微細な揺れで回ってしまわないための不感帯（**度/秒**）。
        /// フレームあたりで書くと、リフレッシュレートによって意味が変わってしまう。
        static var steeringDeadzoneDegreesPerSecond: Double = 2.0

        /// 肩のラインが1フレームでこれ以上動いたら、指の置き直し（再グリップ）とみなして無視する（度）。
        static var regripAngleThresholdDegrees: Double = 25.0

        /// 目を閉じて歩くと人間はまっすぐ歩けない、という現実をそのまま入れる。
        /// 一歩あたりに加わる蛇行の大きさ（度）。0 にすると完全にまっすぐ歩ける。
        static var blindDriftDegreesPerStep: Double = 2.2

        /// 蛇行のランダムウォークの持続性（0...1）。
        /// 大きいほど「同じ方向へ曲がり続けて、じわじわ円を描く」挙動になる。
        static var blindDriftPersistence: Double = 0.88

        /// 速度表示と向きの平滑化時定数（秒）。
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
        static var levelVariation: Double = 0.14
    }

    // MARK: - 回頭のフィードバック

    /// 回頭モードの間だけ鳴る音。
    ///
    /// 回転を「音が自分の周りを回る」形で伝えるための仕掛け。
    /// モードに入った瞬間の**前方**にワールド座標で固定した音源を置き、
    /// そこでカチッと鳴らしてから持続音を出す。
    /// 音源は空間に留まったままなので、体が回るぶんだけ音が横へ流れていく。
    /// カチッはモードに入った合図も兼ねていて、目を閉じていても舵に切り替わったのが分かる。
    enum Rotation {
        static var enabled: Bool = true

        /// 音源を置く距離（メートル）と高さ。近すぎると回転が速すぎて追えない。
        static var distance: Double = 6.0
        static var height: Double = 1.5

        /// 持続音の立ち上がり／消えぎわの時定数（秒）。
        static var fadeInTime: Double = 0.12
        static var fadeOutTime: Double = 0.5

        static var startLevel: Float = 0.9
        static var bedLevel: Float = 0.55
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

    // MARK: - 空間（洞窟）

    /// 広い部屋と狭い通路がつながった洞窟状の空間。
    /// いまいる場所の広さが、そのまま残響の大きさになる。
    enum Cave {
        static var enabled: Bool = true

        /// 部屋の数と、半径の範囲（メートル）。
        static var chamberCount: Int = 12
        static var chamberRadiusRange: ClosedRange<Double> = 3.5...14.0

        /// 部屋どうしの距離の範囲（メートル）。
        static var chamberSpacingRange: ClosedRange<Double> = 12.0...26.0

        /// 部屋をつなぐ通路の半径の範囲（メートル）。
        static var corridorRadiusRange: ClosedRange<Double> = 1.2...2.8

        /// 洞窟の外（岩の中）に出てしまったときに使う広さ。
        static var outsideRadius: Double = 1.0

        /// 広さの変化の平滑化時定数（秒）。
        /// 短いと部屋の境目で残響がガクッと変わる。長いと変化に気づけない。
        static var spaceSmoothing: Double = 0.7
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
        struct Beacon: Equatable {
            /// 位置（メートル）。x = 東、z = 北。洞窟を使うときは部屋の中へ置き直される。
            var x: Double = 0
            var z: Double = 0
            /// 高さ（メートル）。耳の高さから少しずらすと頭外に定位しやすい。
            var height: Double = 1.4
            /// 基音（Hz）。
            ///
            /// - Important: 低い純音は人間が最も定位できない信号（ITD しか手がかりが無く、
            ///   前後の取り違えも起きやすい）。倍音が 1〜3kHz に届く高さにして、
            ///   ILD とスペクトル手がかりが効く帯域にエネルギーを置くこと。
            var frequency: Double
            /// 脈打つ周期（秒）。**アタックのある音でないと定位は立たない。**
            var pulseInterval: Double
            /// 脈の減衰時定数（秒）。
            var pulseDecay: Double = 0.55
            /// 脈と脈の間を埋める持続音の量（0...1）。
            var bedLevel: Double = 0.18
            var level: Float = 0.8
        }

        enum Space {
            static var enabled: Bool = true

            /// 方角の基準音の音色。位置は洞窟の部屋の中から選ばれる。
            static var beacons: [Beacon] = [
                Beacon(frequency: 294.0, pulseInterval: 1.7),
                Beacon(frequency: 392.0, pulseInterval: 2.3),
                Beacon(frequency: 233.0, pulseInterval: 2.9)
            ]

            /// この距離（メートル）から先は減衰しきる。
            static var referenceDistance: Double = 4.0
            static var maximumDistance: Double = 80.0

            /// 残響。頭の中ではなく「外」で鳴っている感じ（頭外定位）が出て、
            /// 方向が格段に読みやすくなる。
            ///
            /// 量は洞窟の広さに連動する。狭い通路では締まり、広間では大きく響く。
            static var reverbEnabled: Bool = true
            /// 狭いとき／広いときの残響レベル（dB）と混ぜ具合。
            static var reverbLevelTightDB: Float = -24
            static var reverbLevelOpenDB: Float = 2
            static var reverbBlendTight: Float = 0.06
            static var reverbBlendOpen: Float = 0.7

            /// 広さに応じて残響のプリセット自体（＝残響の長さ）も切り替えるか。
            /// レベルだけを動かすと「量」は変わっても「空間の大きさ」までは変わらないので、
            /// 洞窟らしさを出すには効くが、切り替えの瞬間にノイズが乗るなら false に。
            static var reverbPresetSwitching: Bool = true
            /// プリセットが行ったり来たりしないための余裕（メートル）。
            static var reverbPresetHysteresis: Double = 0.9
        }
    }

    // MARK: - デバッグ

    enum Debug {
        /// 起動時からデバッグ表示をONにしておくか。
        static var startVisible: Bool = false
    }
}
