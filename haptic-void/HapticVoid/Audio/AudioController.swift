import AVFoundation
import Foundation

/// 音の出力全体。
///
/// 2系統ある:
/// - **足音**: 自分の足元で鳴るので定位させない。`AVAudioSourceNode` でクリックを合成し、
///   左右どちらの足かだけをパンで表す。
/// - **空間音**: `AVAudioEnvironmentNode` の HRTF レンダリングでバイノーラル化する。
///   自分が回頭すると音源が逆向きに回るので、耳だけで方角が読める。
///   現時点では方角の基準になる landmark を1つだけ置いている。
///
/// - Important: 空間定位はヘッドホン前提。スピーカーで鳴らすと定位は失われる。
final class AudioController {

    /// メインスレッド → レンダースレッドへ渡すパラメータ。
    ///
    /// - Note: Int32 / Double の単純な代入のみ（ARM64 では自然境界の word 書き込みは分割されない）で、
    ///   多少のズレが起きても足音の定位がわずかにブレるだけ。プロトタイプとしてはこれで十分なので、
    ///   レンダースレッドでロックを取らない設計にしている。
    private final class SharedParameters {
        var footstepCounter: Int32 = 0
        /// -1 = 完全に左、+1 = 完全に右。
        var footstepPan: Double = 0
    }

    /// レンダースレッドだけが触る状態。
    private final class RenderState {
        var sampleRate: Double = 44_100
        var envelope: Double = 0
        var phase: Double = 0
        var frequency: Double = Tuning.Footstep.clickFrequency
        var gainLeft: Double = 0.5
        var gainRight: Double = 0.5
        var noiseState: UInt32 = 0x9E37_79B9
        var lastFootstepCounter: Int32 = 0

        /// ロックもアロケーションもしない軽量ノイズ（xorshift32）。
        @inline(__always)
        func nextNoise() -> Double {
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 17
            noiseState ^= noiseState << 5
            return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
        }
    }

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let landmarkPlayer = AVAudioPlayerNode()
    private let parameters = SharedParameters()
    private let state = RenderState()

    private var footstepNode: AVAudioSourceNode?
    private var landmarkBuffer: AVAudioPCMBuffer?
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
            startLandmark()
            lastMessage = nil
        } catch {
            lastMessage = "audio engine の起動に失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        landmarkPlayer.stop()
        engine.pause()
        isRunning = false
        state.envelope = 0
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
        landmarkPlayer.stop()
        engine.stop()
        if let node = footstepNode {
            engine.detach(node)
            footstepNode = nil
        }
        engine.detach(landmarkPlayer)
        engine.detach(environment)
        landmarkBuffer = nil
        isGraphBuilt = false
    }

    // MARK: - グラフの組み立て

    private func buildGraphIfNeeded() {
        guard !isGraphBuilt else { return }

        let outputSampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let sampleRate = outputSampleRate > 0 ? outputSampleRate : 44_100
        state.sampleRate = sampleRate

        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            lastMessage = "audio format の生成に失敗"
            return
        }

        engine.attach(environment)
        engine.attach(landmarkPlayer)
        engine.connect(environment, to: engine.mainMixerNode, format: stereoFormat)

        configureEnvironment()

        // 空間音源はモノラルで繋がないと定位が効かない。
        engine.connect(landmarkPlayer, to: environment, format: monoFormat)
        landmarkPlayer.renderingAlgorithm = .HRTFHQ
        landmarkPlayer.position = AVAudio3DPoint(
            x: Float(Tuning.Audio.Landmark.position.x),
            y: Float(Tuning.Audio.Landmark.height),
            z: Float(-Tuning.Audio.Landmark.position.z)   // 北 = -z
        )
        landmarkPlayer.volume = Tuning.Audio.Landmark.level
        landmarkBuffer = makeLandmarkBuffer(format: monoFormat)

        let node = makeFootstepNode(format: stereoFormat)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereoFormat)
        footstepNode = node

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
        attenuation.referenceDistance = Float(Tuning.Audio.Landmark.referenceDistance)
        attenuation.maximumDistance = Float(Tuning.Audio.Landmark.maximumDistance)
        attenuation.rolloffFactor = 1.0
    }

    // MARK: - 方角の基準音（landmark）

    /// ループしても継ぎ目が出ないよう、バッファ長にちょうど整数周期ぶん収まる周波数へ丸めて生成する。
    private func makeLandmarkBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        // ゆらぎ（LFO）1周期ぶんを1ループにする。
        let duration = clamped(1.0 / max(Tuning.Audio.Landmark.lfoFrequency, 0.0001), 4.0, 16.0)
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            lastMessage = "landmark バッファの生成に失敗"
            return nil
        }
        buffer.frameLength = frameCount

        let actualDuration = Double(frameCount) / sampleRate
        // 整数周期に丸める（ここがズレるとループの継ぎ目でプチッと鳴る）。
        let snap: (Double) -> Double = { target in
            let cycles = max(1.0, (target * actualDuration).rounded())
            return cycles / actualDuration
        }
        let base = snap(Tuning.Audio.Landmark.frequency)
        let detuned = snap(Tuning.Audio.Landmark.frequency * Tuning.Audio.Landmark.detuneRatio)
        let lfo = 1.0 / actualDuration
        let depth = clamped01(Tuning.Audio.Landmark.lfoDepth)
        let twoPi = 2.0 * Double.pi

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let amplitude = 1.0 - depth * (0.5 - 0.5 * cos(twoPi * lfo * t))
            var sample = sin(twoPi * base * t) * 0.55
            sample += sin(twoPi * detuned * t) * 0.35
            sample += sin(twoPi * base * 0.5 * t) * 0.18    // 1オクターブ下で芯を出す
            channel[frame] = Float(tanh(sample * amplitude * 0.8))
        }
        return buffer
    }

    private func startLandmark() {
        guard Tuning.Audio.Landmark.enabled,
              let buffer = landmarkBuffer,
              !landmarkPlayer.isPlaying else { return }
        landmarkPlayer.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        landmarkPlayer.play()
    }

    // MARK: - 足音

    private func makeFootstepNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let state = self.state
        let parameters = self.parameters

        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sampleRate = state.sampleRate
            let twoPi = 2.0 * Double.pi

            // 踏んだ瞬間の検出。ブロック先頭で1回だけ読む。
            let counter = parameters.footstepCounter
            if counter != state.lastFootstepCounter {
                state.lastFootstepCounter = counter
                state.envelope = 1.0
                state.phase = 0
                state.frequency = Tuning.Footstep.clickFrequency
                // 等power パンニング。
                let pan = clamped(parameters.footstepPan, -1, 1)
                let angle = (pan + 1) * 0.25 * Double.pi
                state.gainLeft = cos(angle)
                state.gainRight = sin(angle)
            }

            let decay = exp(-1.0 / (sampleRate * max(Tuning.Footstep.clickDecay, 0.001)))
            let noiseMix = clamped01(Tuning.Footstep.clickNoiseMix)
            let level = Tuning.Footstep.clickLevel
            let increment = twoPi * state.frequency / sampleRate

            for frame in 0..<Int(frameCount) {
                var sample = 0.0
                if state.envelope > 0.0001 {
                    state.phase += increment
                    if state.phase > twoPi { state.phase -= twoPi }
                    // 芯（サイン）とノイズを混ぜて素材感を作る。
                    // ノイズ側は包絡の2乗で切ると、アタックだけ硬く鳴って「コツッ」に寄る。
                    let tone = sin(state.phase) * (1 - noiseMix)
                    let noise = state.nextNoise() * noiseMix * state.envelope
                    sample = (tone + noise) * state.envelope * level
                    state.envelope *= decay
                } else {
                    state.envelope = 0
                }

                // 念のためソフトクリップ。
                let leftValue = Float(tanh(sample * state.gainLeft))
                let rightValue = Float(tanh(sample * state.gainRight))
                for (index, buffer) in bufferList.enumerated() {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = index == 0 ? leftValue : rightValue
                }
            }
            return noErr
        }
    }

    /// 一歩ぶんのクリック音。
    func playFootstep(isLeft: Bool) {
        let pan = clamped01(Tuning.Footstep.clickPan)
        parameters.footstepPan = isLeft ? -pan : pan
        parameters.footstepCounter &+= 1
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
