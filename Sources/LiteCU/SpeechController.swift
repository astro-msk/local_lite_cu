import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechController: ObservableObject {
    @Published var transcript = ""
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isFinishing = false
    @Published private(set) var error: String?
    @Published private(set) var recognitionMode = "On-device speech preferred"
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var audioStatus = "Microphone idle"
    @Published private(set) var receivedAudioBuffers = 0

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var hasTap = false
    private var hasEndedAudio = false
    private var audioProbe = AudioProbe()
    private var captureStartedAt: TimeInterval = 0
    private var meterTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var languageName = "the selected language"

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            // AudioEngine posts on its internal queue. Teardown must happen elsewhere.
            Task { @MainActor [weak self] in
                guard let self, self.isListening, !self.audioEngine.isRunning else { return }
                self.fail("The microphone or audio format changed while recording. Check System Settings → Sound → Input, then start dictation again. Your partial transcript is kept.")
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        meterTask?.cancel()
        finishingTask?.cancel()
        recognitionTask?.cancel()
        audioEngine.stop()
        if hasTap { audioEngine.inputNode.removeTap(onBus: 0) }
    }

    func start() async {
        guard !isStarting, !isListening else { return }
        abort()
        let session = UUID()
        sessionID = session
        isStarting = true
        error = nil
        transcript = ""
        audioLevel = 0
        receivedAudioBuffers = 0
        audioProbe = AudioProbe()
        audioStatus = "Preparing microphone…"
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == session else { return }
        guard status == .authorized else {
            fail("Allow Speech Recognition for LiteCU in System Settings → Privacy & Security, or type your command.")
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == session else { return }
        guard microphoneAllowed else {
            fail("Allow Microphone for LiteCU in System Settings → Privacy & Security, or type your command.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail("Apple speech recognition is unavailable for the current language. Check Dictation in System Settings → Keyboard, then retry or type your command.")
            return
        }
        self.recognizer = recognizer
        languageName = Locale.current.localizedString(forIdentifier: recognizer.locale.identifier) ?? recognizer.locale.identifier
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionMode = recognizer.supportsOnDeviceRecognition
            ? "On-device speech · \(languageName)"
            : "Apple network speech · \(languageName) — audio may be sent to Apple"
        self.request = request
        hasEndedAudio = false
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input is available. Select a microphone in System Settings → Sound → Input, or type your command.")
            return
        }
        let probe = audioProbe
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
            probe.record(buffer)
        }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal ?? false
            let errorDetail = recognitionError.map {
                let underlying = $0 as NSError
                return "\(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))"
            }
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == session else { return }
                if let text, !text.isEmpty { self.transcript = text }
                if let errorDetail {
                    let guidance = self.transcript.isEmpty ? self.emptyTranscriptGuidance() : "Your partial transcript is kept; edit it or try dictation again."
                    self.fail("Apple speech recognition: \(errorDetail). \(guidance)")
                } else if finished {
                    let emptyMessage = self.transcript.isEmpty ? self.emptyTranscriptGuidance() : nil
                    self.tearDown(cancelRecognition: false)
                    self.error = emptyMessage
                    self.audioStatus = emptyMessage == nil ? "Transcript ready" : "No speech recognized"
                }
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            isStarting = false
            isListening = true
            audioStatus = "Waiting for microphone audio…"
            startMeter(for: session)
        } catch {
            fail("Could not start the microphone: \(error.localizedDescription). Check System Settings → Sound → Input, then retry.")
        }
    }

    /// Ends microphone capture, then accepts the final result before releasing the recognition task.
    /// The transcript remains editable and is never submitted automatically.
    func stop() {
        guard let session = sessionID else { return }
        guard !isFinishing else { return }
        guard recognitionTask != nil, !isStarting else { abort(); return }
        refreshAudioMetrics()
        stopCapture()
        isFinishing = true
        audioStatus = "Microphone stopped; finishing transcription…"
        endAudio()
        finishingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.sessionID == session, self.isFinishing else { return }
            let guidance = self.transcript.isEmpty ? self.emptyTranscriptGuidance() : "Apple Speech did not finish in time. Your partial transcript is kept; review it before running."
            self.fail(guidance)
        }
    }

    /// Cancels immediately for emergency stop, app termination, or abandoning a voice session.
    func abort() {
        tearDown(cancelRecognition: true)
        audioStatus = transcript.isEmpty ? "Microphone idle" : "Transcript kept"
    }

    private func stopCapture() {
        meterTask?.cancel()
        meterTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        isListening = false
        audioLevel = 0
    }

    private func endAudio() {
        guard !hasEndedAudio else { return }
        hasEndedAudio = true
        request?.endAudio()
    }

    private func tearDown(cancelRecognition: Bool) {
        sessionID = nil
        finishingTask?.cancel()
        finishingTask = nil
        stopCapture()
        endAudio()
        if cancelRecognition { recognitionTask?.cancel() }
        recognitionTask = nil
        request = nil
        recognizer = nil
        isStarting = false
        isFinishing = false
    }

    private func fail(_ message: String) {
        refreshAudioMetrics()
        tearDown(cancelRecognition: true)
        error = message
        audioStatus = transcript.isEmpty ? "Dictation stopped" : "Partial transcript kept"
    }

    private func startMeter(for session: UUID) {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.sessionID == session, self.isListening else { return }
                self.refreshAudioMetrics()
                let metrics = self.audioProbe.snapshot()
                let elapsed = ProcessInfo.processInfo.systemUptime - self.captureStartedAt
                if !self.audioEngine.isRunning {
                    self.fail("The microphone stopped unexpectedly. Check System Settings → Sound → Input, then start dictation again. Your partial transcript is kept.")
                    return
                }
                if metrics.buffers == 0 {
                    self.audioStatus = "Waiting for microphone audio…"
                    if elapsed >= 5 {
                        self.fail(self.emptyTranscriptGuidance())
                        return
                    }
                } else if ProcessInfo.processInfo.systemUptime - metrics.lastBufferAt > 3 {
                    self.fail("Microphone audio stopped arriving. Check the selected input in System Settings → Sound → Input, then retry. Your partial transcript is kept.")
                    return
                } else if elapsed >= 8, self.transcript.isEmpty, metrics.detectedSound {
                    self.audioStatus = "Audio received; waiting for Apple speech recognition…"
                } else if !metrics.canMeasureLevel {
                    self.audioStatus = "Microphone audio received"
                } else if metrics.level > 0.12 {
                    self.audioStatus = "Microphone input detected"
                } else {
                    self.audioStatus = "Microphone connected; input is quiet"
                }
            }
        }
    }

    private func refreshAudioMetrics() {
        let metrics = audioProbe.snapshot()
        receivedAudioBuffers = metrics.buffers
        audioLevel = metrics.level
    }

    private func emptyTranscriptGuidance() -> String {
        let metrics = audioProbe.snapshot()
        if metrics.buffers == 0 {
            return "No microphone audio arrived. Select your microphone in System Settings → Sound → Input and check its input level, then retry or type your command."
        }
        if metrics.canMeasureLevel, !metrics.detectedSound {
            return "The microphone input stayed quiet. Check the selected microphone and input volume in System Settings → Sound → Input, then retry or type your command."
        }
        return "Audio reached the app, but Apple Speech returned no transcript. Check that Dictation is enabled for \(languageName) in System Settings → Keyboard, then retry or type your command."
    }
}

/// The audio callback publishes only scalar diagnostics, never recordings or audio buffers.
/// UI polling avoids scheduling a main-actor task for every audio buffer.
private final class AudioProbe: @unchecked Sendable {
    struct Metrics {
        var buffers = 0
        var level: Double = 0
        var lastBufferAt: TimeInterval = 0
        var detectedSound = false
        var canMeasureLevel = false
    }
    private let lock = NSLock()
    private var metrics = Metrics()

    func record(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }
        var rms: Double?
        if let channels = buffer.floatChannelData {
            var maximumPower: Double = 0
            for channel in 0..<channelCount {
                let samples = channels[buffer.format.isInterleaved ? 0 : channel]
                var sum: Double = 0
                for frame in 0..<frameCount {
                    let index = buffer.format.isInterleaved ? frame * channelCount + channel : frame
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
                maximumPower = max(maximumPower, sum / Double(frameCount))
            }
            rms = sqrt(maximumPower)
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        metrics.buffers += 1
        metrics.lastBufferAt = now
        if let rms, rms.isFinite {
            metrics.canMeasureLevel = true
            let decibels = 20 * log10(max(rms, 0.000_001))
            metrics.level = max(0, min(1, (decibels + 60) / 60))
            metrics.detectedSound = metrics.detectedSound || decibels > -48
        }
        lock.unlock()
    }

    func snapshot() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }
}
