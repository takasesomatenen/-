import AVFoundation
import Foundation

/// 音の出力全体。
///
/// 3系統ある:
/// - **足音**: 自分の足元で鳴るので定位させない。録音サンプルを左右のパンだけで振り分ける。
/// - **基準音（beacon）**: 洞窟の部屋に置いた、脈打ち続ける方角の手がかり。
/// - **回頭のフィードバック**: 回り始めた瞬間の前方にワールド固定で置く音。
///   体が回るぶんだけ横へ流れていくので、「自分の周りを音が回る」形で回転が聴こえる。
///
/// 空間音は `AVAudioEnvironmentNode` の HRTF レンダリングでバイノーラル化している。
/// 残響の量と長さは、いまいる場所の広さに連動する。
///
/// - Important: 空間定位はヘッドホン前提。スピーカーで鳴らすと定位は失われる。
final class AudioController {

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    /// 方角の基準音。音源ごとに1本ずつプレイヤーを持つ。
    private var beaconPlayers: [AVAudioPlayerNode] = []
    private var configuredBeacons: [Tuning.Audio.Beacon] = []

    /// 足音の再生プール。連続した一歩が互いを切らないよう複数本を使い回す。
    private var footstepPlayers: [AVAudioPlayerNode] = []
    private var footstepIndex = 0
    private var footstepLeft: AVAudioPCMBuffer?
    private var footstepRight: AVAudioPCMBuffer?

    /// 回頭のフィードバック。開始のワンショットと、回っている間の持続音。
    private let rotationStartPlayer = AVAudioPlayerNode()
    private let rotationBedPlayer = AVAudioPlayerNode()
    private var rotationStartBuffer: AVAudioPCMBuffer?
    private var rotationBedBuffer: AVAudioPCMBuffer?
    private var rotationBedVolume: Float = 0
    private var rotationBedTarget: Float = 0

    /// 残響の現在値（無駄な再設定を避けるため）。
    private var lastReverbLevel: Double = .nan
    private var lastReverbBlend: Double = .nan
    private var currentPresetBand: Int = -1

    private var isRunning = false
    private var isGraphBuilt = false
    private var configurationObserver: NSObjectProtocol?

    private(set) var lastMessage: String?

    init() {
        // ヘッドホンの抜き差しなどでオーディオグラフが作り直されたときに復帰する。
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            // 出力のサンプルレートが変わっている可能性があるので、グラフごと作り直す。
            let beacons = self.configuredBeacons
            self.teardownGraph()
            self.isRunning = false
            self.start(beacons: beacons)
        }
    }

    deinit {
        if let configurationObserver = configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - ライフサイクル

    /// - Parameter beacons: 洞窟の中に置かれた基準音。前回と違えばグラフを組み直す。
    func start(beacons: [Tuning.Audio.Beacon]) {
        guard Tuning.Audio.enabled else { return }
        if isGraphBuilt, beacons != configuredBeacons {
            teardownGraph()
            isRunning = false
        }
        guard !isRunning else { return }

        configuredBeacons = beacons
        configureSession()
        buildGraphIfNeeded()
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            for player in beaconPlayers where !player.isPlaying {
                player.play()
            }
            // 足音と回頭のプレイヤーは鳴らしっぱなしにしておく。
            // 停止状態から play() を挟むと、そのぶん遅れて聴こえるため。
            for player in footstepPlayers where !player.isPlaying {
                player.play()
            }
            if !rotationStartPlayer.isPlaying { rotationStartPlayer.play() }
            lastMessage = nil
        } catch {
            lastMessage = "audio engine の起動に失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        rotationBedTarget = 0
        rotationBedVolume = 0
        for player in beaconPlayers + footstepPlayers + [rotationStartPlayer, rotationBedPlayer] {
            player.stop()
        }
        engine.pause()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 他アプリの音楽と混ぜられるようにしておく（環境音として重ねて遊べる）。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            lastMessage = "audio session の設定に失敗: \(error.localizedDescription)"
        }
    }

    private func teardownGraph() {
        let all = beaconPlayers + footstepPlayers + [rotationStartPlayer, rotationBedPlayer]
        for player in all {
            player.stop()
            engine.detach(player)
        }
        engine.stop()
        engine.detach(environment)
        beaconPlayers = []
        footstepPlayers = []
        footstepLeft = nil
        footstepRight = nil
        rotationStartBuffer = nil
        rotationBedBuffer = nil
        rotationBedVolume = 0
        rotationBedTarget = 0
        lastReverbLevel = .nan
        lastReverbBlend = .nan
        currentPresetBand = -1
        isGraphBuilt = false
    }

    // MARK: - グラフの組み立て

    private func buildGraphIfNeeded() {
        guard !isGraphBuilt else { return }

        let outputSampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let sampleRate = outputSampleRate > 0 ? outputSampleRate : 48_000

        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            lastMessage = "audio format の生成に失敗"
            return
        }

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereoFormat)
        configureEnvironment()

        if Tuning.Audio.Space.enabled, Tuning.Audio.Space.beaconsEnabled {
            for beacon in configuredBeacons {
                guard let buffer = makeBeaconBuffer(beacon, format: monoFormat) else { continue }
                let player = AVAudioPlayerNode()
                attachSpatial(player, format: monoFormat)
                player.position = AVAudio3DPoint(x: Float(beacon.x),
                                                 y: Float(beacon.height),
                                                 z: Float(-beacon.z))   // 北 = -z
                player.volume = beacon.level
                player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
                beaconPlayers.append(player)
            }
        }

        // 回頭のフィードバックも空間音として鳴らす（回っているのが分かる要はここ）。
        rotationStartBuffer = loadBuffer(named: "RotateStart")
        rotationBedBuffer = loadBuffer(named: "RotateBed")
        attachSpatial(rotationStartPlayer, format: monoFormat)
        attachSpatial(rotationBedPlayer, format: monoFormat)
        rotationStartPlayer.volume = Tuning.Rotation.startLevel
        rotationBedPlayer.volume = 0

        footstepLeft = loadBuffer(named: "Footstep_L")
        footstepRight = loadBuffer(named: "Footstep_R")
        if let format = footstepLeft?.format {
            for _ in 0..<4 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                // 足元の音なので定位はさせず、ミキサーへ直結してパンだけ効かせる。
                engine.connect(player, to: engine.mainMixerNode, format: format)
                footstepPlayers.append(player)
            }
        }

        engine.mainMixerNode.outputVolume = Tuning.Audio.masterVolume
        isGraphBuilt = true
    }

    /// 空間音源として環境ノードへ繋ぐ。**モノラルで繋がないと定位が効かない。**
    private func attachSpatial(_ player: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        player.renderingAlgorithm = .HRTFHQ
        player.reverbBlend = Tuning.Audio.Space.reverbBlendTight
    }

    private func configureEnvironment() {
        // ヘッドホン前提で HRTF を効かせる。
        environment.outputType = .headphones
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = Float(Tuning.Audio.Space.referenceDistance)
        attenuation.maximumDistance = Float(Tuning.Audio.Space.maximumDistance)
        attenuation.rolloffFactor = 1.0

        environment.reverbParameters.enable = Tuning.Audio.Space.reverbEnabled
    }

    // MARK: - 空間の広さ → 残響

    /// いまいる場所の広さを残響へ反映する。
    ///
    /// - レベルと混ぜ具合は連続的に動かす（響きの「量」）
    /// - プリセットは段階的に切り替える（響きの「長さ」＝空間の大きさそのもの）
    ///   行ったり来たりしないようヒステリシスを入れてある。
    /// - Parameter radius: いまいる場所の広さ（メートル）
    func updateSpace(radius: Double) {
        guard isGraphBuilt, Tuning.Audio.Space.reverbEnabled else { return }

        let tight = Tuning.Cave.corridorRadiusRange.lowerBound
        let open = Tuning.Cave.chamberRadiusRange.upperBound
        let t = clamped01((radius - tight) / max(open - tight, 0.001))

        let level = lerp(Double(Tuning.Audio.Space.reverbLevelTightDB),
                         Double(Tuning.Audio.Space.reverbLevelOpenDB), t)
        if !(abs(level - lastReverbLevel) < 0.15) {
            environment.reverbParameters.level = Float(level)
            lastReverbLevel = level
        }

        let blend = lerp(Double(Tuning.Audio.Space.reverbBlendTight),
                         Double(Tuning.Audio.Space.reverbBlendOpen), t)
        if !(abs(blend - lastReverbBlend) < 0.01) {
            for player in beaconPlayers + [rotationStartPlayer, rotationBedPlayer] {
                player.reverbBlend = Float(blend)
            }
            lastReverbBlend = blend
        }

        if Tuning.Audio.Space.reverbPresetSwitching {
            updateReverbPreset(radius: radius)
        }
    }

    /// 広さの段階に応じて残響の「長さ」を変える。
    private func updateReverbPreset(radius: Double) {
        // 境界（メートル）。狭い通路 → 小部屋 → 広間 → 洞窟。
        let thresholds: [Double] = [3.0, 6.0, 10.0]
        let hysteresis = Tuning.Audio.Space.reverbPresetHysteresis

        var band = 0
        for (index, threshold) in thresholds.enumerated() {
            // いま下の段にいるなら上がるのに余裕ぶん多く、上の段にいるなら下がるのに余裕ぶん少なく。
            let edge = currentPresetBand > index ? threshold - hysteresis : threshold + hysteresis
            if radius >= edge { band = index + 1 }
        }
        guard band != currentPresetBand else { return }
        currentPresetBand = band

        let presets: [AVAudioUnitReverbPreset] = [.smallRoom, .mediumRoom, .largeHall, .cathedral]
        environment.reverbParameters.loadFactoryReverbPreset(presets[min(band, presets.count - 1)])
        // プリセットを読み込むとレベルが既定へ戻るので、入れ直す。
        if lastReverbLevel.isFinite {
            environment.reverbParameters.level = Float(lastReverbLevel)
        }
    }

    // MARK: - 方角の基準音

    /// 脈打つ基準音を1周期ぶん合成する。
    ///
    /// 定位できる音にするための条件が2つある:
    /// - **アタックがあること**。持続音だけだと両耳への到達時間差が読めず、方向が立たない。
    /// - **倍音が 1〜3kHz に届くこと**。低い純音は ILD がほぼ生まれず、前後の取り違えも起きる。
    ///
    /// 脈の減衰が周期の終わりでゼロに落ちるので、ループの継ぎ目は自然に消える。
    private func makeBeaconBuffer(_ beacon: Tuning.Audio.Beacon,
                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = clamped(beacon.pulseInterval, 0.4, 8.0)
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            lastMessage = "基準音バッファの生成に失敗"
            return nil
        }
        buffer.frameLength = frameCount

        let twoPi = 2.0 * Double.pi
        // 倍音を上へ伸ばして、定位の効く帯域にエネルギーを置く。
        let partials: [(ratio: Double, gain: Double)] = [
            (1.0, 1.00), (2.0, 0.52), (3.0, 0.30), (5.0, 0.18), (8.0, 0.10)
        ]
        let partialSum = partials.reduce(0) { $0 + $1.gain }
        let decay = max(beacon.pulseDecay, 0.05)
        let attack = 0.012
        let bed = clamped01(beacon.bedLevel)
        let actualDuration = Double(frameCount) / sampleRate

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate

            // 脈: 速いアタックと指数減衰。
            var envelope = exp(-t / decay)
            if t < attack { envelope *= t / attack }

            var sample = 0.0
            for partial in partials {
                sample += sin(twoPi * beacon.frequency * partial.ratio * t) * partial.gain
            }
            sample /= partialSum

            // 脈の間を埋める持続音。手がかりが完全に途切れないようにするため。
            let bedTone = sin(twoPi * beacon.frequency * 0.5 * t) * bed

            var value = sample * envelope + bedTone
            // ループ末尾を必ずゼロに落として継ぎ目を消す。
            let tail = actualDuration * 0.08
            if t > actualDuration - tail {
                value *= (actualDuration - t) / tail
            }
            channel[frame] = Float(tanh(value * 0.8))
        }
        return buffer
    }

    // MARK: - 回頭のフィードバック

    /// 回り始めた地点の前方に音源を置き、開始音を鳴らして持続音を立ち上げる。
    ///
    /// 音源はワールド座標に固定したままにする。体が回ってもここは動かないので、
    /// 回ったぶんだけ音が横へ流れる＝回転そのものが聴こえる。
    func beginRotationCue(x: Double, z: Double) {
        guard isRunning, Tuning.Rotation.enabled else { return }
        let position = AVAudio3DPoint(x: Float(x), y: Float(Tuning.Rotation.height), z: Float(-z))
        rotationStartPlayer.position = position
        rotationBedPlayer.position = position

        if let buffer = rotationStartBuffer {
            rotationStartPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !rotationStartPlayer.isPlaying { rotationStartPlayer.play() }
        }
        if let buffer = rotationBedBuffer, !rotationBedPlayer.isPlaying {
            rotationBedPlayer.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            rotationBedPlayer.volume = rotationBedVolume
            rotationBedPlayer.play()
        }
        rotationBedTarget = Tuning.Rotation.bedLevel
    }

    /// 回るのをやめたので持続音を消す。
    func endRotationCue() {
        rotationBedTarget = 0
    }

    /// 持続音の出入りを毎フレーム進める。
    func updateFades(dt: Double) {
        guard isGraphBuilt else { return }
        let rising = rotationBedTarget > rotationBedVolume
        let tau = rising ? Tuning.Rotation.fadeInTime : Tuning.Rotation.fadeOutTime
        rotationBedVolume = Float(smoothed(current: Double(rotationBedVolume),
                                           target: Double(rotationBedTarget),
                                           tau: tau, dt: dt))
        rotationBedPlayer.volume = rotationBedVolume

        // 消えきったら止める。次に回り始めたときにループを入れ直す。
        if rotationBedTarget == 0, rotationBedVolume < 0.004, rotationBedPlayer.isPlaying {
            rotationBedPlayer.stop()
            rotationBedVolume = 0
        }
    }

    // MARK: - 足音

    private func loadBuffer(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            lastMessage = "\(name).wav が見つかりません"
            return nil
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                lastMessage = "\(name).wav のバッファ確保に失敗"
                return nil
            }
            try file.read(into: buffer)
            return buffer
        } catch {
            lastMessage = "\(name).wav の読み込みに失敗: \(error.localizedDescription)"
            return nil
        }
    }

    /// 一歩ぶんの足音。
    func playFootstep(isLeft: Bool) {
        guard isRunning, !footstepPlayers.isEmpty else { return }
        guard let buffer = isLeft ? footstepLeft : footstepRight else { return }

        let player = footstepPlayers[footstepIndex]
        footstepIndex = (footstepIndex + 1) % footstepPlayers.count

        let pan = clamped(Double(Tuning.Footstep.pan), 0, 1)
        player.pan = Float(isLeft ? -pan : pan)

        // 同じ波形の連打は機械的に聴こえるので、一歩ごとに音量をわずかに散らす。
        let variation = clamped01(Tuning.Footstep.levelVariation)
        let jitter = 1.0 - Double.random(in: 0...variation)
        player.volume = Tuning.Footstep.level * Float(jitter)

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - リスナー

    /// 自分の位置と向きを空間音のリスナーへ反映する。
    /// - Parameters:
    ///   - x: 東方向（メートル）
    ///   - z: 北方向（メートル）
    ///   - headingRadians: 北を0とした時計回りの角度
    func updateListener(x: Double, z: Double, headingRadians: Double) {
        guard isGraphBuilt else { return }
        // ワールドの北を -z に対応させている（AVAudio のリスナーは初期状態で -z を向いている）。
        environment.listenerPosition = AVAudio3DPoint(x: Float(x), y: 0, z: Float(-z))
        // yaw は反時計回りが正なので、時計回りの heading とは符号が逆になる。
        let yaw = -headingRadians * 180 / .pi
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: Float(yaw), pitch: 0, roll: 0
        )
    }
}
