import AVFoundation
import Foundation

/// 音の出力全体。
///
/// 2系統ある:
/// - **足音**: 自分の足元で鳴るので定位させない。録音サンプルを左右のパンだけで振り分ける。
/// - **空間音**: `AVAudioEnvironmentNode` の HRTF レンダリングでバイノーラル化する。
///   自分が回頭すると音源が逆向きに回るので、耳だけで方角が読める。
///
/// - Important: 空間定位はヘッドホン前提。スピーカーで鳴らすと定位は失われる。
final class AudioController {

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    /// 方角の基準音。音源ごとに1本ずつプレイヤーを持つ。
    private var beaconPlayers: [AVAudioPlayerNode] = []

    /// 足音の再生プール。連続した一歩が互いを切らないよう複数本を使い回す。
    private var footstepPlayers: [AVAudioPlayerNode] = []
    private var footstepIndex = 0
    private var footstepLeft: AVAudioPCMBuffer?
    private var footstepRight: AVAudioPCMBuffer?

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
            self.teardownGraph()
            self.isRunning = false
            self.start()
        }
    }

    deinit {
        if let configurationObserver = configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - ライフサイクル

    func start() {
        guard Tuning.Audio.enabled, !isRunning else { return }
        configureSession()
        buildGraphIfNeeded()
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            startBeacons()
            // 足音のプレイヤーは鳴らしっぱなしにしておく。
            // 停止状態から play() を挟むと一歩ぶん遅れて聴こえるため。
            for player in footstepPlayers where !player.isPlaying {
                player.play()
            }
            lastMessage = nil
        } catch {
            lastMessage = "audio engine の起動に失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        for player in beaconPlayers + footstepPlayers {
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
        for player in beaconPlayers + footstepPlayers {
            player.stop()
            engine.detach(player)
        }
        engine.stop()
        beaconPlayers = []
        footstepPlayers = []
        engine.detach(environment)
        footstepLeft = nil
        footstepRight = nil
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

        if Tuning.Audio.Space.enabled {
            for beacon in Tuning.Audio.Space.beacons {
                guard let buffer = makeBeaconBuffer(beacon, format: monoFormat) else { continue }
                let player = AVAudioPlayerNode()
                engine.attach(player)
                // 空間音源はモノラルで繋がないと定位が効かない。
                engine.connect(player, to: environment, format: monoFormat)
                player.renderingAlgorithm = .HRTFHQ
                player.position = AVAudio3DPoint(x: Float(beacon.x),
                                                 y: Float(beacon.height),
                                                 z: Float(-beacon.z))   // 北 = -z
                player.volume = beacon.level
                player.reverbBlend = Tuning.Audio.Space.reverbBlend
                player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
                beaconPlayers.append(player)
            }
        }

        loadFootstepBuffers()
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

        // わずかな残響。音が頭の中ではなく「外」で鳴っている感じ（頭外定位）を作る。
        // これが無いと、方向は合っていても距離感が出ずに向きが読みにくい。
        let reverb = environment.reverbParameters
        reverb.enable = Tuning.Audio.Space.reverbEnabled
        if Tuning.Audio.Space.reverbEnabled {
            reverb.loadFactoryReverbPreset(.mediumRoom)
            reverb.level = Tuning.Audio.Space.reverbLevelDB
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
            sample /= partials.reduce(0) { $0 + $1.gain }

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

    private func startBeacons() {
        for player in beaconPlayers where !player.isPlaying {
            player.play()
        }
    }

    // MARK: - 足音

    /// バンドルに入れた録音サンプルを読み込む。
    private func loadFootstepBuffers() {
        footstepLeft = loadBuffer(named: "Footstep_L")
        footstepRight = loadBuffer(named: "Footstep_R")
    }

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
