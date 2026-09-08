import CoreGraphics
import Foundation

/// ゲーム全体のチューニングパラメータ。
///
/// 実機で触りながら「数値だけ」を触って調整できるよう、ロジックからは完全に分離してある。
/// すべて `static var` なので、デバッグUIやプレイ中のコードから書き換えても即座に反映される。
enum Tuning {

    // MARK: - 空間 / 距離

    enum Space {
        /// 到達判定の半径（画面短辺に対する比率）。
        /// 大きくすると「当たり」やすくなり、小さくすると精密な探索を要求する。
        static var arrivalRadiusRatio: Double = 0.055

        /// 触覚・音が反応する最大距離（画面対角線に対する比率）。
        /// この距離以上離れると強度は最小値に張り付く。
        static var senseRangeRatio: Double = 0.80

        /// ターゲットを置くときの画面端マージン（短辺比率）。
        /// 端すぎると指が届きにくいので少し内側に寄せる。
        static var spawnMarginRatio: Double = 0.14

        /// 次のターゲットは「前回のターゲット」「現在の指の位置」からこれ以上離す（短辺比率）。
        static var respawnSeparationRatio: Double = 0.40
    }

    // MARK: - 触覚

    enum Haptics {
        /// 連続触覚の強度レンジ。
        static var minIntensity: Double = 0.0
        static var maxIntensity: Double = 1.0

        /// 近さ(0...1)から強度へ変換するときの指数。
        /// - 1.0 : 線形
        /// - >1  : 近くに来るまで弱いまま（探索が難しく・達成感が強い）
        /// - <1  : 遠くからでも感じ取れる（やさしい）
        static var intensityGamma: Double = 2.0

        /// パターンに埋め込む基準シャープネス。
        /// Core Haptics の `hapticSharpnessControl` は「相対オフセット」なので、
        /// ここを中央値(0.5)にしておくと上下どちらにも振れる。
        static var baseSharpness: Double = 0.5

        /// 方向が分からないとき（静止時）のシャープネス。
        static var neutralSharpness: Double = 0.5
        /// 近づいている時のシャープネス（低い＝滑らか・まろやか）。
        static var approachingSharpness: Double = 0.05
        /// 遠ざかっている時のシャープネス（高い＝ざらつく・警告的）。
        static var recedingSharpness: Double = 0.95

        /// 接近速度（正規化距離/秒）がこの値に達したとき、方向表現が振り切れる。
        /// 小さくすると少し動かしただけで方向が出る（敏感）。
        static var approachRateFullScale: Double = 1.2

        /// 各種平滑化の時定数（秒）。小さいほど機敏、大きいほどぬるっとする。
        static var approachRateSmoothing: Double = 0.10
        static var intensitySmoothing: Double = 0.05
        static var sharpnessSmoothing: Double = 0.12

        /// 指を離した／到達した瞬間のフェードアウト時定数（秒）。
        static var releaseFade: Double = 0.20
        /// 指を置いた瞬間の立ち上がり時定数（秒）。
        static var attackTime: Double = 0.04

        /// 遠いときの「ゆらぎ（不規則さ）」の最大量。0にすると完全に滑らかなグラデーションになる。
        static var farJitterAmount: Double = 0.35
        /// ゆらぎがシャープネス側に効く割合。
        static var farJitterSharpnessScale: Double = 0.5
        /// ゆらぎのランダムウォークの時定数（秒）。小さいほどガサガサする。
        static var farJitterSmoothing: Double = 0.07

        /// このしきい値以下の変化ならパラメータ送信を省略する（無駄な送信を減らす）。
        static var parameterEpsilon: Double = 0.004
    }

    // MARK: - 音

    enum Audio {
        /// 音を鳴らすかどうか。触覚だけの体験を試したいときは false に。
        static var enabled: Bool = true

        /// 最遠（proximity = 0）と最近（proximity = 1）の周波数。
        /// 対数補間するので、音楽的に自然なピッチ変化になる。
        static var lowFrequency: Double = 138.59   // C#3
        static var highFrequency: Double = 415.30  // G#4
        static var frequencyGamma: Double = 1.0

        /// 音量レンジ（0...1）。
        static var minAmplitude: Double = 0.0
        static var maxAmplitude: Double = 0.22
        static var amplitudeGamma: Double = 1.6

        /// レンダースレッド側でのパラメータ平滑化時定数（秒）。ジッパーノイズ防止。
        static var parameterSmoothing: Double = 0.08

        /// パッドらしさを出すための、ゆっくりした音量ゆらぎ。
        static var padLFOFrequency: Double = 0.11
        static var padLFODepth: Double = 0.18

        /// デチューン量（うなりの速さ）と、サブオシレータ（1オクターブ下）の混合量。
        static var detuneRatio: Double = 1.006
        static var subLevel: Double = 0.30

        /// 到達時のチャイム。
        static var chimeLevel: Double = 0.28
        static var chimeDecay: Double = 0.9        // 減衰時定数（秒）
        static var chimeIntervalRatio: Double = 1.5 // 到達時のピッチ（現在の音に対する比。1.5 = 完全5度上）

        /// 出力全体のマスターボリューム。
        static var masterVolume: Float = 0.9
    }

    // MARK: - ラウンド進行

    enum Round {
        /// 到達してから次のターゲットが出るまでの余韻（秒）。
        static var arrivalHoldSeconds: Double = 1.6
    }

    // MARK: - デバッグ

    enum Debug {
        /// 起動時からデバッグ表示をONにしておくか。
        static var startVisible: Bool = false
    }
}
