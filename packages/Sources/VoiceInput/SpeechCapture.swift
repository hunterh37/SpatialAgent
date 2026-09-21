#if canImport(Speech) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Speech

/// On-device dictation for the character. Partial transcripts stream out as they arrive so
/// the character can enter `listening` before the sentence ends (spec/02-interaction.md);
/// the final transcript is what goes to `agentd`.
///
/// `requiresOnDeviceRecognition` is forced: nothing about the room is allowed to leave the
/// device, and that includes what is said in it (docs/architecture.md §2c).
@MainActor
public final class SpeechCapture: ObservableObject {
    public enum Status: Equatable {
        case idle
        case denied(String)
        case listening
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    /// Live transcript, replaced on every partial result.
    @Published public private(set) var transcript: String = ""

    public var isListening: Bool { status == .listening }

    /// Called with each partial transcript, then once with the final one.
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func toggle() async {
        if isListening { stop() } else { await start() }
    }

    public func start() async {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            status = .failed("Speech recognition isn't available right now.")
            return
        }
        guard await Self.authorize() else {
            status = .denied("Microphone or speech access is off in Settings.")
            return
        }

        do {
            try configureSession()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = .failed(error.localizedDescription)
            teardown()
            return
        }

        transcript = ""
        status = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    if result.isFinal {
                        self.finish(with: text)
                    } else {
                        self.onPartial?(text)
                    }
                }
                if error != nil {
                    // A recognition error mid-utterance still yields whatever was heard;
                    // dropping it silently would look like the mic did nothing.
                    self.finish(with: self.transcript)
                }
            }
        }
    }

    /// Ends the utterance. The final transcript is delivered through `onFinal`.
    public func stop() {
        guard isListening else { return }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // `endAudio` usually produces a final result; this guards the case where it does not.
        if !transcript.isEmpty { finish(with: transcript) } else { teardown() }
    }

    public func cancel() {
        task?.cancel()
        transcript = ""
        teardown()
    }

    private func finish(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        guard !trimmed.isEmpty else { return }
        onFinal?(trimmed)
    }

    private func teardown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.finish()
        task = nil
        request = nil
        if case .listening = status { status = .idle }
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureSession() throws {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        #if os(macOS)
        return true
        #else
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #endif
    }
}
#endif
