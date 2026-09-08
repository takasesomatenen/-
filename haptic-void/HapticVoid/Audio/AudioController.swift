import AVFoundation
import Foundation

/// 距離に連動して連続変化するサイン波パッドと、到達時のチャイムを鳴らす。
///
/// AVAudioSourceNode でサンプルを直接生成しているので、
/// 音源ファイルを一切持たずにピッチ／音量を連続的に動かせる。
final class AudioController {

    /// メインスレッド → レンダースレッドへ渡すパラメータ。
    ///
    /// - Note: Double / Int32 の単純な代入のみ（ARM64 では自然境界の word 書き込みは分割されない）で、
    ///   多少のズレが起きても音がわずかに遅れるだけ。プロトタイプとしてはこれで十分なので、
    ///   レンダースレッドでロックを取らない設計にしている。
    private final class SharedParameters {
        var frequency: Double = Tuning.Audio.lowFrequency
        var amplitude: Double = 0
        var chimeFrequency: Double = 440
        var chimeCounter: Int32 = 0
    }

    /// レンダースレッドだけが触る状態。
    private final class RenderState {
        var sampleRate: Double = 44_100
        var frequency: Double = Tuning.Audio.lowFrequency
        var amplitude: Double = 0
        var phaseMain: Double = 0
        var phaseDetune: Double = 0
        var phaseSub: Double = 0
        var phaseLFO: Double = 0
        var chimeEnvelope: Double = 0
        var chimeFrequency: Double = 440
        var chimePhase: Double = 0
        var chimePhaseOctave: Double = 0
        var lastChimeCounter: Int32 = 0
    }

    private let engine = AVAudioEngine()
    private let parameters = SharedParameters()
    private let state = RenderState()
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false
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
            self.isRunning = false
            self.engine.stop()
            if let node = self.sourceNode {
                self.engine.detach(node)
                self.sourceNode = nil
            }
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
            lastMessage = nil
        } catch {
            lastMessage = "audio engine の起動に失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.pause()
        isRunning = false
        parameters.amplitude = 0
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

    private func buildGraphIfNeeded() {
        guard sourceNode == nil else { return }

        let outputSampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let sampleRate = outputSampleRate > 0 ? outputSampleRate : 44_100
        state.sampleRate = sampleRate

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            lastMessage = "audio format の生成に失敗"
            return
        }

        let state = self.state
        let parameters = self.parameters

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sampleRate = state.sampleRate
            let twoPi = 2.0 * Double.pi

            // ブロック先頭で目標値を1回だけ読む。
            let targetFrequency = parameters.frequency
            let targetAmplitude = parameters.amplitude

            // 到達チャイムのトリガ検出。
            let chimeCounter = parameters.chimeCounter
            if chimeCounter != state.lastChimeCounter {
                state.lastChimeCounter = chimeCounter
                state.chimeEnvelope = 1.0
                state.chimePhase = 0
                state.chimePhaseOctave = 0
                state.chimeFrequency = parameters.chimeFrequency
            }

            // 1サンプルあたりの平滑化係数。
            let smoothing = 1.0 - exp(-1.0 / (sampleRate * max(Tuning.Audio.parameterSmoothing, 0.001)))
            let chimeDecay = exp(-1.0 / (sampleRate * max(Tuning.Audio.chimeDecay, 0.001)))
            let lfoIncrement = twoPi * Tuning.Audio.padLFOFrequency / sampleRate
            let lfoDepth = Tuning.Audio.padLFODepth
            let detuneRatio = Tuning.Audio.detuneRatio
            let subLevel = Tuning.Audio.subLevel
            let chimeLevel = Tuning.Audio.chimeLevel

            for frame in 0..<Int(frameCount) {
                state.frequency += (targetFrequency - state.frequency) * smoothing
                state.amplitude += (targetAmplitude - state.amplitude) * smoothing

                state.phaseLFO += lfoIncrement
                if state.phaseLFO > twoPi { state.phaseLFO -= twoPi }
                let lfo = 1.0 - lfoDepth * (0.5 - 0.5 * cos(state.phaseLFO))

                let increment = twoPi * state.frequency / sampleRate
                state.phaseMain += increment
                state.phaseDetune += increment * detuneRatio
                state.phaseSub += increment * 0.5
                if state.phaseMain > twoPi { state.phaseMain -= twoPi }
                if state.phaseDetune > twoPi { state.phaseDetune -= twoPi }
                if state.phaseSub > twoPi { state.phaseSub -= twoPi }

                var sample = sin(state.phaseMain) * 0.50
                    + sin(state.phaseDetune) * 0.32
                    + sin(state.phaseSub) * subLevel
                sample *= state.amplitude * lfo

                if state.chimeEnvelope > 0.0001 {
                    let chimeIncrement = twoPi * state.chimeFrequency / sampleRate
                    state.chimePhase += chimeIncrement
                    state.chimePhaseOctave += chimeIncrement * 2.0
                    if state.chimePhase > twoPi { state.chimePhase -= twoPi }
                    if state.chimePhaseOctave > twoPi { state.chimePhaseOctave -= twoPi }
                    let chime = (sin(state.chimePhase) + 0.35 * sin(state.chimePhaseOctave))
                        * state.chimeEnvelope * chimeLevel
                    sample += chime
                    state.chimeEnvelope *= chimeDecay
                }

                // 念のためソフトクリップ。
                let value = Float(tanh(sample))
                for buffer in bufferList {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Tuning.Audio.masterVolume
        sourceNode = node
    }

    // MARK: - パラメータ更新

    /// 距離に応じた音を更新する。
    /// - Parameters:
    ///   - proximity: 0（最遠）〜 1（ターゲット上）
    ///   - gain: 指を離した／到達したときのフェード用エンベロープ（0...1）
    func update(proximity: Double, gain: Double) {
        let p = clamped01(proximity)
        let g = clamped01(gain)

        // ピッチは対数補間（音楽的に自然な変化になる）。
        let ratio = Tuning.Audio.highFrequency / Tuning.Audio.lowFrequency
        parameters.frequency = Tuning.Audio.lowFrequency * pow(ratio, pow(p, Tuning.Audio.frequencyGamma))

        let level = Tuning.Audio.minAmplitude
            + (Tuning.Audio.maxAmplitude - Tuning.Audio.minAmplitude) * pow(p, Tuning.Audio.amplitudeGamma)
        parameters.amplitude = level * g
    }

    /// 到達時のチャイム。現在のピッチから完全5度上あたりで鳴らす。
    func playArrivalChime() {
        parameters.chimeFrequency = parameters.frequency * Tuning.Audio.chimeIntervalRatio
        parameters.chimeCounter &+= 1
    }
}
