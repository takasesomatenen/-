import CoreHaptics
import Foundation

/// Core Haptics のエンジンとパターンプレイヤーを管理する。
///
/// 設計方針:
/// - 探索中は「終わらない連続イベント（hapticContinuous）」を1本だけ鳴らしっぱなしにし、
///   強度と鋭さは Dynamic Parameters でリアルタイムに書き換える。
///   （毎回パターンを作り直すと途切れてしまい、連続的なグラデーションにならない）
/// - 到達時だけ、明確に区別できる別パターン（トランジェントの連打）を重ねる。
final class HapticsController {

    /// この端末で Core Haptics が使えるか。シミュレータでは常に false。
    let supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// デバッグ表示用の最後のエラー。
    private(set) var lastMessage: String?

    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var arrivalPlayer: CHHapticPatternPlayer?
    private var isContinuousRunning = false

    /// 直近に送ったパラメータ（無駄な送信を省くため）。
    private var lastSentIntensity: Double = -1
    private var lastSentSharpness: Double = -1

    // MARK: - ライフサイクル

    /// エンジンを用意する。多重呼び出しは無害。
    func prepare() {
        guard supportsHaptics else {
            lastMessage = "この端末では Core Haptics を利用できません（シミュレータ／非対応機種）"
            return
        }
        guard engine == nil else { return }

        do {
            let engine = try CHHapticEngine()
            // 音は AVAudioEngine 側で作るので、触覚だけを扱わせる（負荷とレイテンシが下がる）。
            engine.playsHapticsOnly = true
            // 指が止まっている間に勝手に停止されると再開のもたつきが出るので自動停止は切る。
            engine.isAutoShutdownEnabled = false

            // 端末側の都合でエンジンがリセットされた場合の復帰処理。
            engine.resetHandler = { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastMessage = "haptic engine was reset"
                    self.continuousPlayer = nil
                    let shouldResume = self.isContinuousRunning
                    self.isContinuousRunning = false
                    do {
                        try self.engine?.start()
                        if shouldResume { self.startContinuous() }
                    } catch {
                        self.lastMessage = "engine restart failed: \(error.localizedDescription)"
                    }
                }
            }

            // 割り込み（電話・アプリ切り替えなど）で止まった場合。
            engine.stoppedHandler = { [weak self] reason in
                DispatchQueue.main.async {
                    self?.isContinuousRunning = false
                    self?.lastMessage = "haptic engine stopped (reason: \(reason.rawValue))"
                }
            }

            try engine.start()
            self.engine = engine
            lastMessage = nil
        } catch {
            lastMessage = "haptic engine の起動に失敗: \(error.localizedDescription)"
        }
    }

    /// アプリがバックグラウンドに入るときなどに呼ぶ。
    func shutdown() {
        stopContinuous()
        arrivalPlayer = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        continuousPlayer = nil
    }

    // MARK: - 連続触覚

    func startContinuous() {
        guard supportsHaptics else { return }
        prepare()
        guard let engine = engine, !isContinuousRunning else { return }

        do {
            if continuousPlayer == nil {
                // 強度・鋭さはあとから Dynamic Parameters で書き換えるので、
                // ここでは「基準値」を入れておくだけ。
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness,
                                               value: Float(Tuning.Haptics.baseSharpness))
                    ],
                    relativeTime: 0,
                    duration: 8.0
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makeAdvancedPlayer(with: pattern)
                // ループさせて「終わらない振動」にする。loopEnd = 0 はパターン末尾までを意味する。
                player.loopEnabled = true
                player.loopEnd = 0
                continuousPlayer = player
            }

            try continuousPlayer?.start(atTime: CHHapticTimeImmediate)
            isContinuousRunning = true

            // 鳴り始めの不意打ちを避けるため、開始直後に無音まで絞る。
            lastSentIntensity = -1
            lastSentSharpness = -1
            updateContinuous(intensity: 0, sharpness: Tuning.Haptics.neutralSharpness, force: true)
        } catch {
            lastMessage = "連続触覚の開始に失敗: \(error.localizedDescription)"
        }
    }

    func stopContinuous() {
        guard isContinuousRunning else { return }
        try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        isContinuousRunning = false
        lastSentIntensity = -1
        lastSentSharpness = -1
    }

    /// 連続触覚の強度・鋭さを絶対値（0...1）で更新する。
    ///
    /// - Note: Core Haptics の Dynamic Parameter のうち
    ///   `hapticIntensityControl` はイベント強度への「乗算」(0...1)、
    ///   `hapticSharpnessControl` はイベント鋭さへの「加算オフセット」(-1...1) として働く。
    ///   ここでは呼び出し側が絶対値だけを意識すればよいよう、内部でオフセットに変換している。
    func updateContinuous(intensity: Double, sharpness: Double, force: Bool = false) {
        guard isContinuousRunning || force, let player = continuousPlayer else { return }

        let targetIntensity = clamped01(intensity)
        let targetSharpness = clamped01(sharpness)

        if !force {
            let epsilon = Tuning.Haptics.parameterEpsilon
            let intensityChanged = abs(targetIntensity - lastSentIntensity) >= epsilon
            let sharpnessChanged = abs(targetSharpness - lastSentSharpness) >= epsilon
            guard intensityChanged || sharpnessChanged else { return }
        }

        let sharpnessOffset = clamped(targetSharpness - Tuning.Haptics.baseSharpness, -1, 1)
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                     value: Float(targetIntensity), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                     value: Float(sharpnessOffset), relativeTime: 0)
        ]

        do {
            try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
            lastSentIntensity = targetIntensity
            lastSentSharpness = targetSharpness
        } catch {
            lastMessage = "パラメータ送信に失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - 動作確認

    /// 実機で触覚が動いているかを確かめるためのセルフテスト。
    ///
    /// 「弱く・ざらついた振動」から「強く・滑らかな振動」へ2秒かけて連続的に変化させ、
    /// 最後に到達パターン相当のパルスを鳴らす。
    /// このゲームで使っている表現（強度グラデーション＋鋭さの変化＋トランジェント）を
    /// ひととおり通すので、これが感じられれば本編も動く。
    /// - Returns: 再生を開始できたら true。
    @discardableResult
    func playSelfTest() -> Bool {
        guard supportsHaptics else {
            lastMessage = "この端末では Core Haptics を利用できません（シミュレータ／非対応機種）"
            return false
        }
        prepare()
        guard let engine = engine else { return false }
        guard !isContinuousRunning else { return false }

        let sweepDuration: TimeInterval = 2.0
        do {
            var events: [CHHapticEvent] = [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness,
                                               value: Float(Tuning.Haptics.baseSharpness))
                    ],
                    relativeTime: 0,
                    duration: sweepDuration
                )
            ]
            // 仕上げのパルス（到達パターンと同じ質感）。
            let pulseTimes: [TimeInterval] = [sweepDuration + 0.15, sweepDuration + 0.235, sweepDuration + 0.32]
            for time in pulseTimes {
                events.append(
                    CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                        ],
                        relativeTime: time
                    )
                )
            }

            // 弱い → 強い
            let intensityCurve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.05),
                    CHHapticParameterCurve.ControlPoint(relativeTime: sweepDuration, value: 1.0)
                ],
                relativeTime: 0
            )
            // ざらつき → 滑らか（baseSharpness からの相対オフセット）
            let sharpnessCurve = CHHapticParameterCurve(
                parameterID: .hapticSharpnessControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.45),
                    CHHapticParameterCurve.ControlPoint(relativeTime: sweepDuration, value: -0.45)
                ],
                relativeTime: 0
            )

            let pattern = try CHHapticPattern(events: events,
                                              parameterCurves: [intensityCurve, sharpnessCurve])
            let player = try engine.makePlayer(with: pattern)
            arrivalPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            lastMessage = nil
            return true
        } catch {
            lastMessage = "セルフテストの再生に失敗: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 到達フィードバック

    /// 到達したことがはっきり分かる専用パターン。
    /// 連続グラデーションとは明確に質感を変えるため、短いトランジェントの3連打＋余韻にしている。
    func playArrival() {
        guard supportsHaptics else { return }
        prepare()
        guard let engine = engine else { return }

        do {
            var events: [CHHapticEvent] = []
            let pulses: [(time: TimeInterval, intensity: Float, sharpness: Float)] = [
                (0.00, 1.00, 0.75),
                (0.085, 0.80, 0.50),
                (0.170, 1.00, 0.25)
            ]
            for pulse in pulses {
                events.append(
                    CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness)
                        ],
                        relativeTime: pulse.time
                    )
                )
            }
            // 余韻：やわらかい連続振動をゆっくり消す。
            events.append(
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05)
                    ],
                    relativeTime: 0.19,
                    duration: 0.55
                )
            )
            let decay = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0.0, value: 1.0),
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0.55, value: 0.0)
                ],
                relativeTime: 0.19
            )

            let pattern = try CHHapticPattern(events: events, parameterCurves: [decay])
            let player = try engine.makePlayer(with: pattern)
            // プレイヤーが解放されると再生も止まるので参照を保持しておく。
            arrivalPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            lastMessage = "到達パターンの再生に失敗: \(error.localizedDescription)"
        }
    }
}
