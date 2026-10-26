import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechController: ObservableObject {
    @Published var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var error: String?
    @Published private(set) var recognitionMode = "On-device speech preferred"

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var hasTap = false

    func start() async {
        guard sessionID == nil else { return }
        let session = UUID()
        sessionID = session
        error = nil
        transcript = ""
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == session else { return }
        guard status == .authorized else {
            error = "Allow Speech Recognition for LiteCU in System Settings → Privacy & Security, or type your command."
            stop()
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == session else { return }
        guard microphoneAllowed else {
            error = "Allow Microphone for LiteCU in System Settings → Privacy & Security, or type your command."
            stop()
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            error = "Speech recognition is unavailable for the current language. Type your command instead."
            stop()
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionMode = recognizer.supportsOnDeviceRecognition
            ? "On-device speech"
            : "Apple network speech — audio may be sent to Apple"
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "No microphone input is available. Connect a microphone or type your command."
            stop()
            return
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal ?? false
            let message = recognitionError?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == session else { return }
                if let text { self.transcript = text }
                if let message {
                    self.error = "Speech recognition: \(message) You can edit the transcript or type a command."
                    self.stop()
                } else if finished {
                    self.stop()
                }
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            self.error = "Could not start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    /// Stops capture and preserves the current transcript for review; it never submits a command.
    func stop() {
        sessionID = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        isListening = false
    }
}
