import AVFoundation
import Speech
import SnagbookCore

/// Speech to text into the item that was shown when dictation started, recognised on this
/// Mac by the system's dictation models (macOS 26 and newer; the button is hidden before).
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, preparing(String), listening, finishing }

    @Published private(set) var phase: Phase = .idle
    private unowned let model: AppModel
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnyObject>.Continuation?
    /// Silence fed before the input ends, so a word cut off by the Stop press is still heard.
    private var tail: AVAudioPCMBuffer?
    private var finish: (() async -> Void)?
    private var generation = 0
    /// Self-test stand-in for a slow model download, in seconds.
    var preparationDelay: Double?

    init(model: AppModel) { self.model = model }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var isActive: Bool { phase != .idle }

    var buttonTitle: String {
        switch phase {
        case .idle: return "Dictate"
        case .preparing: return "Preparing…"
        case .listening: return "Stop Dictating"
        case .finishing: return "Finishing…"
        }
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .listening, .preparing: stop()
        case .finishing: break
        }
    }

    /// Languages the system can dictate, as (BCP-47 id, name in the user's language), by name.
    static func languages() async -> [(id: String, name: String)] {
        guard #available(macOS 26.0, *) else { return [] }
        return await DictationTranscriber.supportedLocales
            .map { ($0.identifier(.bcp47), displayName($0.identifier(.bcp47))) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    static func displayName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// `audioFile` replaces the microphone (the self-test speaks through it, in real time).
    func start(audioFile: URL? = nil) {
        guard phase == .idle, #available(macOS 26.0, *) else { return }
        generation += 1
        let run = generation
        phase = .preparing("Preparing…")
        Task {
            do {
                try await begin(run: run, audioFile: audioFile)
            } catch {
                guard generation == run else { return }
                await abandon(run: run)
                model.show(error)
            }
        }
    }

    func stop() {
        if isPreparing {
            generation += 1
            phase = .idle
            return
        }
        guard phase == .listening else { return }
        phase = .finishing
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if let tail { input?.yield(tail) }
        tail = nil
        input?.finish()
        input = nil
        let done = finish
        finish = nil
        let run = generation
        Task {
            await done?()
            if generation == run { phase = .idle }
        }
    }

    /// Stops and waits until the last words are in the note (quitting).
    func stopAndWait() async {
        if isActive { stop() }
        while phase != .idle { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private var isPreparing: Bool { if case .preparing = phase { return true } else { return false } }

    private func abandon(run: Int) async {
        guard generation == run else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        input?.finish()
        input = nil
        finish = nil
        phase = .idle
    }

    @available(macOS 26.0, *)
    private func begin(run: Int, audioFile: URL?) async throws {
        /// Stop (or a newer start) during any wait below abandons this one.
        func current() throws { if generation != run { throw CancellationError() } }
        let (session, item) = try await model.dictationTarget()
        try current()
        guard let identity = model.openedItemIdentity(item) else { throw SnagError.noSuchItem(item) }
        if audioFile == nil { try await Self.requireMicrophone() }
        try current()

        let wanted = model.config.dictationLanguage.map { Locale(identifier: $0) } ?? Locale.current
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw DictationError("Dictation is not available in \(Self.displayName(wanted.identifier(.bcp47))). Choose another language from the Dictate button's menu.")
        }
        let name = Self.displayName(locale.identifier(.bcp47))
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let preparationDelay { try await Task.sleep(nanoseconds: UInt64(preparationDelay * 1e9)) }
        try current()
        if let download {
            phase = .preparing("Downloading \(name)…")
            try await download.downloadAndInstall()
            try current()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try current()
        guard let format else {
            throw DictationError("Dictation could not find an audio format for \(name).")
        }

        let (stream, continuation) = AsyncStream<AnyObject>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputs = stream.compactMap { ($0 as? AVAudioPCMBuffer).map { AnalyzerInput(buffer: $0) } }
        try await analyzer.start(inputSequence: inputs)
        guard generation == run else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return
        }

        let model = self.model
        let results = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    try await model.dictated(text, session: session, item: item, identity: identity)
                }
            } catch {
                model.show(error)
            }
        }
        finish = {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = await results.value
        }
        input = continuation
        tail = Self.silence(format, seconds: 0.6)

        if let audioFile {
            Self.play(audioFile, to: format, into: continuation)
        } else {
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let source = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: source, to: format) else {
                throw DictationError("Dictation cannot use this microphone's audio format.")
            }
            node.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
                if let converted = Self.convert(buffer, with: converter, to: format) { continuation.yield(converted) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
        }
        phase = .listening
        model.flash("Dictating in \(name): speak, then press Dictate again to stop")
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    nonisolated private static func silence(_ format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        return buffer
    }

    /// Feeds a file at the speed it would be spoken, like a microphone; stop() ends the input.
    nonisolated private static func play(_ url: URL, to format: AVAudioFormat, into continuation: AsyncStream<AnyObject>.Continuation) {
        Thread.detachNewThread {
            guard let file = try? AVAudioFile(forReading: url),
                  let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return }
            let chunk: AVAudioFrameCount = 4096
            while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                if let converted = convert(buffer, with: converter, to: format) { continuation.yield(converted) }
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / file.processingFormat.sampleRate)
            }
        }
    }

    private static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw DictationError("Snagbook may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then try again.")
    }
}

struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
