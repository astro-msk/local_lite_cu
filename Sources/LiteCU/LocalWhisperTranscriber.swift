import AVFoundation
import Foundation
import Darwin

/// Local speech-to-text only. The model and executable are installed separately;
/// this type never downloads anything or sends microphone audio over a network.
struct LocalWhisperTranscriber {
    struct Configuration {
        let executable: URL
        let model: URL

        static func installed() throws -> Configuration {
            let manager = FileManager.default
            let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
                              "/opt/homebrew/opt/whisper.cpp/bin/whisper-cli"]
            guard let path = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
                throw WhisperError.unavailable("Local Whisper is not installed. Install whisper.cpp with Homebrew, then restart dictation.")
            }
            let model = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LiteCU/Models/ggml-small.en.bin")
            guard manager.isReadableFile(atPath: model.path) else {
                throw WhisperError.unavailable("Whisper small.en is missing. Place ggml-small.en.bin in ~/Library/Application Support/LiteCU/Models, then retry.")
            }
            return Configuration(executable: URL(fileURLWithPath: path), model: model)
        }
    }

    enum WhisperError: LocalizedError {
        case unavailable(String)
        case audio(String)
        case transcription(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .audio(let message), .transcription(let message): return message
            }
        }
    }

    static func makeSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteCU-Whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// The caller owns the private session directory and removes it on completion/cancellation.
    func transcribe(recording: URL, configuration: Configuration) async throws -> String {
        try Task.checkCancellation()
        let directory = recording.deletingLastPathComponent()
        let wav = directory.appendingPathComponent("audio.wav")
        try Self.convertToWAV(recording, destination: wav)
        try Task.checkCancellation()

        let output = directory.appendingPathComponent("transcript")
        let log = directory.appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = ["-m", configuration.model.path, "-f", wav.path,
                             "-l", "en", "-t", "4", "-nt", "-np", "-sns", "-otxt", "-of", output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        let control = WhisperProcessControl(process)
        try await withTaskCancellationHandler {
            try control.start()
            let deadline = Date().addingTimeInterval(120)
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    guard Date() < deadline else {
                        throw WhisperError.transcription("Local Whisper took too long. Try a shorter recording.")
                    }
                    let logSize = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard logSize <= 1_048_576 else {
                        throw WhisperError.transcription("Local Whisper produced too much diagnostic output. Check the installation and retry.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                control.stop()
                // Do not release the audio files while the subprocess can still read them.
                await control.waitUntilStopped()
                throw error
            }
        } onCancel: {
            control.stop()
        }
        guard process.terminationStatus == 0 else {
            // Keep diagnostics local; do not place audio or transcript contents in an error.
            throw WhisperError.transcription("Local Whisper could not transcribe this recording (exit \(process.terminationStatus)). Check the model installation and try again.")
        }
        let textURL = output.appendingPathExtension("txt")
        guard FileManager.default.isReadableFile(atPath: textURL.path) else {
            throw WhisperError.transcription("Whisper finished without a transcript. Try dictating again.")
        }
        let text = try String(contentsOf: textURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let marker = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSpeech = ["[blank_audio]", "[silence]", "[no speech]", "[music]", "(music)", "(silence)", "♪", "♫"]
        return nonSpeech.contains(marker) ? "" : text
    }

    /// AVAudioConverter handles microphone sample rates and channel counts without ffmpeg.
    static func convertToWAV(_ source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: mono),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4_096) else {
            throw WhisperError.audio("The recording contains no usable microphone audio.")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                      AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                      AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, state in
                guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: inputBuffer, frameCount: min(requested, inputBuffer.frameCapacity))
                    state.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return inputBuffer.frameLength > 0 ? inputBuffer : nil
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            if status == .endOfStream { break }
            if status == .error { throw WhisperError.audio("Could not convert the microphone recording for Whisper.") }
        }
    }
}

/// Cancellation can arrive before Process.run; the lock closes that race.
private final class WhisperProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    init(_ process: Process) { self.process = process }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func stop() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
