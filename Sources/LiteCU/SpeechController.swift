import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechController: ObservableObject {
    /// Fired once per successful capture, after all busy flags are cleared.
    var onFinalTranscript: ((String) -> Void)?
    @Published var transcript = ""
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isFinishing = false
    @Published private(set) var error: String?
    @Published private(set) var recognitionMode = "Whisper small.en · on this Mac · English"
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var audioStatus = "Microphone idle"
    @Published private(set) var receivedAudioBuffers = 0

    private let audioEngine = AVAudioEngine()
    private var sessionID: UUID?
    private var hasTap = false
    private var audioProbe = AudioProbe()
    private var recording: WhisperRecording?
    private var captureDirectory: URL?
    private var configuration: LocalWhisperTranscriber.Configuration?
    private var captureStartedAt: TimeInterval = 0
    private var meterTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, !self.audioEngine.isRunning else { return }
                self.fail("The microphone changed while recording. Check System Settings → Sound → Input, then dictate again.")
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        meterTask?.cancel()
        finishingTask?.cancel()
        audioEngine.stop()
        if hasTap { audioEngine.inputNode.removeTap(onBus: 0) }
        recording?.close()
        if let captureDirectory { try? FileManager.default.removeItem(at: captureDirectory) }
    }

    func start() async {
        guard !isStarting, !isListening, !isFinishing else { return }
        abort()
        let session = UUID()
        sessionID = session
        isStarting = true
        error = nil
        audioLevel = 0
        receivedAudioBuffers = 0
        audioProbe = AudioProbe()
        audioStatus = "Preparing local Whisper…"
        do { configuration = try LocalWhisperTranscriber.Configuration.installed() }
        catch { fail(error.localizedDescription); return }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == session else { return }
        if Task.isCancelled { abort(); return }
        guard microphoneAllowed else {
            fail("Allow Microphone for Lite CU in System Settings → Privacy & Security, or type your command.")
            return
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input is available. Select a microphone in System Settings → Sound → Input.")
            return
        }
        do {
            let directory = try LocalWhisperTranscriber.makeSessionDirectory()
            captureDirectory = directory
            let writer = try WhisperRecording(url: directory.appendingPathComponent("recording.caf"), format: format)
            recording = writer
            let probe = audioProbe
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                writer.append(buffer)
                probe.record(buffer)
            }
            hasTap = true
            audioEngine.prepare()
            try audioEngine.start()
            transcript = ""
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            isStarting = false
            isListening = true
            audioStatus = "Recording on your Mac; pause or click Stop to transcribe"
            startMeter(for: session)
        } catch {
            fail("Could not record microphone audio: \(error.localizedDescription)")
        }
    }

    /// Finishes capture immediately, then transcribes the saved audio offline.
    /// AppModel decides whether the final transcript contains the user's execution phrase.
    func stop() {
        guard let session = sessionID, !isFinishing else { return }
        guard isListening, let writer = recording, let directory = captureDirectory,
              let configuration else { abort(); return }
        refreshAudioMetrics()
        stopCapture()
        writer.close()
        if let message = writer.failure { fail("Could not save microphone audio: \(message)"); return }
        let metrics = audioProbe.snapshot()
        guard metrics.buffers > 0, !metrics.canMeasureLevel || metrics.detectedSound else {
            fail(emptyTranscriptGuidance())
            return
        }
        // The finishing task now owns the files, including cleanup after cancellation.
        captureDirectory = nil
        recording = nil
        isFinishing = true
        audioStatus = "Transcribing on your Mac with Whisper…"
        finishingTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let text = try await LocalWhisperTranscriber().transcribe(recording: writer.url, configuration: configuration)
                try Task.checkCancellation()
                guard let self, self.sessionID == session else { return }
                self.finishingTask = nil
                self.sessionID = nil
                self.isFinishing = false
                self.configuration = nil
                if text.isEmpty {
                    self.error = "Whisper did not recognize speech. Try again with a clearer, shorter command."
                    self.audioStatus = "No speech recognized"
                } else {
                    self.transcript = text
                    self.error = nil
                    self.audioStatus = "Transcript ready to review"
                    self.onFinalTranscript?(text)
                }
            } catch is CancellationError {
                // abort() has already reset UI state. A cancelled session cannot publish text.
            } catch {
                guard let self, self.sessionID == session else { return }
                self.finishingTask = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    func abort() {
        sessionID = nil
        finishingTask?.cancel()
        finishingTask = nil
        stopCapture()
        recording?.close()
        recording = nil
        if let captureDirectory { try? FileManager.default.removeItem(at: captureDirectory) }
        captureDirectory = nil
        configuration = nil
        isStarting = false
        isFinishing = false
        audioStatus = transcript.isEmpty ? "Microphone idle" : "Transcript kept"
    }

    private func stopCapture() {
        meterTask?.cancel()
        meterTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if hasTap { audioEngine.inputNode.removeTap(onBus: 0); hasTap = false }
        isListening = false
        audioLevel = 0
    }

    private func fail(_ message: String) {
        refreshAudioMetrics()
        abort()
        error = message
        audioStatus = "Dictation stopped"
    }

    private func startMeter(for session: UUID) {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.sessionID == session, self.isListening else { return }
                self.refreshAudioMetrics()
                let metrics = self.audioProbe.snapshot()
                let elapsed = ProcessInfo.processInfo.systemUptime - self.captureStartedAt
                if let message = self.recording?.failure {
                    self.fail("Could not save microphone audio: \(message)")
                    return
                }
                if !self.audioEngine.isRunning {
                    self.fail("The microphone stopped. Check System Settings → Sound → Input, then dictate again.")
                    return
                }
                if elapsed >= 60 || (elapsed >= 1 && metrics.soundDuration >= 0.3
                                    && ProcessInfo.processInfo.systemUptime - metrics.lastSoundAt >= 2) {
                    self.stop()
                    return
                }
                if metrics.buffers == 0 {
                    self.audioStatus = "Waiting for microphone audio…"
                    if elapsed >= 5 { self.fail(self.emptyTranscriptGuidance()); return }
                } else if ProcessInfo.processInfo.systemUptime - metrics.lastBufferAt > 3 {
                    self.fail("Microphone audio stopped arriving. Check System Settings → Sound → Input, then retry.")
                    return
                } else if !metrics.canMeasureLevel || metrics.level > 0.12 {
                    self.audioStatus = "Recording on your Mac; pause or click Stop to transcribe"
                } else {
                    self.audioStatus = "Recording; microphone input is quiet"
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
        if audioProbe.snapshot().buffers == 0 {
            return "No microphone audio arrived. Select your microphone in System Settings → Sound → Input, then retry."
        }
        return "The recording was quiet. Check the microphone and input volume in System Settings → Sound → Input, then retry."
    }
}

/// The engine callback and Stop can race; closing under the same lock prevents
/// writes after capture has ended. The containing directory is private (0700).
private final class WhisperRecording: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var writeError: String?
    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, writeError == nil else { return }
        do { try file.write(from: buffer) } catch { writeError = error.localizedDescription }
    }
    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return writeError
    }
    func close() {
        lock.lock()
        file = nil
        lock.unlock()
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
        var lastSoundAt: TimeInterval = 0
        var soundDuration: TimeInterval = 0
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
            if decibels > -48 {
                metrics.lastSoundAt = now
                metrics.soundDuration += Double(frameCount) / buffer.format.sampleRate
            }
        }
        lock.unlock()
    }

    func snapshot() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }
}
