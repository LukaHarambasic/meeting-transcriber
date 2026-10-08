import AudioTapLib
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MicSpeechMonitor")

// MARK: - MicSpeechTracker

/// The bookkeeping half of the monitor: given a verdict per chunk, when did
/// speech last happen. A plain value so a test can drive it with synthetic
/// verdicts and a fake clock, without loading the speech model.
///
/// It reports nothing until the first verdict arrives. A recording with no
/// microphone channel never delivers a buffer, and "not listening" must not
/// read as "listening and hearing nothing", which is the empty-room signal.
struct MicSpeechTracker: Equatable {
    private var startedAt: Date?
    private var lastSpeech: Date?

    /// Fold in one chunk's verdict. `inSpeech` is the VAD's own hysteresis
    /// state (between its start and end events), not a raw per-chunk
    /// probability, so a short pause inside a sentence still counts as speech.
    mutating func record(at now: Date, inSpeech: Bool) {
        if startedAt == nil { startedAt = now }
        if inSpeech { lastSpeech = now }
    }

    /// The detector died mid-recording. A reading frozen at the last verdict
    /// would age into "nobody has spoken for a long time", which is a false
    /// claim, so go back to reporting no evidence at all.
    mutating func invalidate() {
        self = Self()
    }

    var reading: MicSpeechReading {
        guard let startedAt else { return .unavailable }
        return .listening(since: startedAt, lastSpeech: lastSpeech)
    }
}

// MARK: - MicSpeechChunker

/// Re-slices a stream of 16 kHz mono buffers of arbitrary length into the
/// fixed chunks the Silero model takes. Capture buffers never line up with the
/// model's 4096 samples, so the remainder carries over to the next buffer.
struct MicSpeechChunker {
    static let chunkSize = VadManager.chunkSize

    private var pending: [Float] = []

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        var consumed = 0
        while pending.count - consumed >= Self.chunkSize {
            chunks.append(Array(pending[consumed ..< consumed + Self.chunkSize]))
            consumed += Self.chunkSize
        }
        pending.removeFirst(consumed)
        return chunks
    }
}

// MARK: - ChunkVerdict

/// What the consumer task reports per chunk. Three cases instead of an
/// optional Bool, because "the detector died" is a verdict of its own and must
/// not be confusable with "quiet".
enum ChunkVerdict {
    case speech
    case quiet
    case failed
}

// MARK: - SpeechChunkClassifying

/// Stateful per-recording verdict on consecutive chunks. A seam so the
/// monitor's threading and wiring can be tested without the CoreML model; the
/// production conformer is `FluidVADSpeechClassifier`.
protocol SpeechChunkClassifying: Sendable {
    /// Feed the next chunk (exactly `MicSpeechChunker.chunkSize` samples) and
    /// say whether the stream is currently inside speech.
    func isSpeech(_ chunk: [Float]) async throws -> Bool
}

/// `FluidVAD`'s streaming API behind `SpeechChunkClassifying`. Going through
/// `FluidVAD` rather than a bare `VadManager` reuses its single-flight model
/// load and its clear-on-failure retry, instead of a second copy of both.
actor FluidVADSpeechClassifier: SpeechChunkClassifying {
    private let vad: FluidVAD
    private var state: FluidVAD.StreamState

    private init(vad: FluidVAD, state: FluidVAD.StreamState) {
        self.vad = vad
        self.state = state
    }

    /// Loads the model (the slow part, seconds on a cold start) and opens a
    /// fresh stream.
    static func load() async throws -> FluidVADSpeechClassifier {
        let vad = FluidVAD()
        return try await FluidVADSpeechClassifier(vad: vad, state: vad.makeStreamState())
    }

    func isSpeech(_ chunk: [Float]) async throws -> Bool {
        let result = try await vad.processStreamingChunk(chunk, state: state)
        state = result.state
        return state.triggered
    }
}

// MARK: - MicSpeechMonitor

/// Tells the quiet-room auto-stop when the microphone last heard speech.
///
/// Fed only by the microphone's `LiveAudioSink`, never the app/system tap:
/// music playing through the system mix is what fooled the old level-based
/// attendance check, and a voice activity model on the mic alone cannot be
/// fooled by it.
///
/// Threading: the sink runs on the audio callback thread, so it only yields
/// into a bounded `AsyncStream` under a lock (same shape as the captions'
/// channel feed). One detached task per recording does the resampling,
/// chunking and inference, and writes the verdict into a lock-guarded tracker
/// that `reading()` snapshots from the main actor. A generation counter keeps
/// a task from a finished recording out of the next one's tracker.
///
/// `@unchecked Sendable`: all mutable state lives behind `shared`'s lock.
final class MicSpeechMonitor: @unchecked Sendable {
    /// Bounded feed capacity, in buffers. Capture delivers tens of buffers a
    /// second, so this is many seconds of headroom for the one slow stretch
    /// (the first model load); beyond that the stream drops the oldest audio,
    /// which for a "has anyone spoken lately" signal costs nothing.
    private static let capacity = 512

    private struct Shared {
        var tracker = MicSpeechTracker()
        var continuation: AsyncStream<LiveAudioBuffer>.Continuation?
        var task: Task<Void, Never>?
        var generation = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let makeClassifier: @Sendable () async throws -> any SpeechChunkClassifying
    private let now: @Sendable () -> Date

    init(
        makeClassifier: @escaping @Sendable () async throws -> any SpeechChunkClassifying = {
            try await FluidVADSpeechClassifier.load()
        },
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.makeClassifier = makeClassifier
        self.now = now
    }

    deinit {
        shared.withLock { state in
            state.continuation?.finish()
            state.task?.cancel()
        }
    }

    /// What the detector has heard so far in the current recording. Cheap and
    /// safe from any thread.
    func reading() -> MicSpeechReading {
        shared.withLock { $0.tracker.reading }
    }

    /// Start a fresh listening session, retiring any previous one. The reading
    /// stays `.unavailable` until the model has loaded and a first chunk has
    /// been judged.
    func begin() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveAudioBuffer.self,
            bufferingPolicy: .bufferingNewest(Self.capacity),
        )
        shared.withLock { state in
            state.continuation?.finish()
            state.task?.cancel()
            state.generation += 1
            state.tracker = MicSpeechTracker()
            state.continuation = continuation
            let generation = state.generation
            let makeClassifier = makeClassifier
            // Weak, so a task still parked on the model load cannot keep a
            // dropped monitor alive.
            let record: @Sendable (ChunkVerdict) -> Void = { [weak self] verdict in
                self?.record(verdict, generation: generation)
            }
            state.task = Task.detached(priority: .utility) {
                await Self.consume(stream, makeClassifier: makeClassifier, record: record)
            }
        }
    }

    /// Stop listening and drop what was heard.
    func end() {
        shared.withLock { state in
            state.generation += 1
            state.continuation?.finish()
            state.continuation = nil
            state.task?.cancel()
            state.task = nil
            state.tracker = MicSpeechTracker()
        }
    }

    /// The microphone sink for `DualSourceRecorder.micLiveSink`. Forwards to
    /// `existing` first, so live captions keep receiving every buffer
    /// untouched, then yields into this monitor's feed. Returns immediately:
    /// no task spawn and no actor hop on the audio thread.
    func sink(teeing existing: LiveAudioSink?) -> LiveAudioSink {
        let shared = shared
        return { buffer in
            existing?(buffer)
            shared.withLock { state in
                _ = state.continuation?.yield(buffer)
            }
        }
    }

    private func record(_ verdict: ChunkVerdict, generation: Int) {
        let stamp = now()
        shared.withLock { state in
            guard state.generation == generation else { return }
            switch verdict {
            case .speech: state.tracker.record(at: stamp, inSpeech: true)
            case .quiet: state.tracker.record(at: stamp, inSpeech: false)
            case .failed: state.tracker.invalidate()
            }
        }
    }

    /// The consumer: load the classifier, then resample, chunk and classify
    /// every buffer in arrival order. A load or inference failure ends the
    /// session and reports `.failed`, which voids the reading: the quiet-room rule
    /// treats that as no evidence, never as silence.
    private static func consume(
        _ stream: AsyncStream<LiveAudioBuffer>,
        makeClassifier: @Sendable () async throws -> any SpeechChunkClassifying,
        record: @Sendable (ChunkVerdict) -> Void,
    ) async {
        let classifier: any SpeechChunkClassifying
        do {
            classifier = try await makeClassifier()
        } catch {
            logger.warning("Mic speech model unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Built here so the non-Sendable converter stays confined to this task.
        let resampler = LiveAudioResampler()
        var chunker = MicSpeechChunker()
        for await buffer in stream {
            guard let mono = resampler.resample(buffer) else { continue }
            for chunk in chunker.append(mono.samples) {
                if Task.isCancelled { return }
                do {
                    try await record(classifier.isSpeech(chunk) ? .speech : .quiet)
                } catch {
                    logger.warning("Mic speech inference failed: \(error.localizedDescription, privacy: .public)")
                    record(.failed)
                    return
                }
            }
        }
    }
}
