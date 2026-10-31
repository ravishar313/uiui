import Foundation

/// Owns decoder handles independently of the Core ML encoder. The caller must
/// configure only on its serial owner executor while no decode is in flight.
/// Replacement is transactional: failure never publishes a partial worker set.
final class VocabularyDecoderPool {
    struct Handles {
        let workers: [TDTDecoder]
        let fast: TDTDecoder
    }
    let tables: DecoderTables
    private let workerCount: Int
    private let workerThreads: Int32
    private let fastThreads: Int32
    private let checkCancellation: (() throws -> Void)?
    private let selective: Bool
    private(set) var handles: Handles
    private(set) var activeVocabularyCount = 0
    private var configuredWords: [String] = []

    init(tables: DecoderTables, workerCount: Int, workerThreads: Int32,
         fastThreads: Int32, serialExecution: Bool = false, selective: Bool = true, checkCancellation: (() throws -> Void)?) throws {
        self.tables = tables
        self.selective = selective
        self.workerCount = serialExecution ? 0 : max(1, workerCount)
        self.workerThreads = workerThreads
        self.fastThreads = max(1, fastThreads)
        self.checkCancellation = checkCancellation
        // The serial transcriber always uses fast, including long windows and
        // rescue. Do not clone an idle native worker with its own state/scratch.
        handles = try Self.build(tables: tables, words: [], workerCount: self.workerCount,
                                 workerThreads: workerThreads, fastThreads: max(1, fastThreads), selective: selective,
                                 checkCancellation: checkCancellation)
    }

    static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for raw in words {
            // Check a generous raw bound before allocating normalized strings.
            guard raw.count <= 1024 else { continue }
            let word = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !word.isEmpty, word.count <= 80,
                  seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count == 100 { break }
        }
        return result.sorted()
    }

    func configureVocabulary(_ words: [String]) throws {
        try configureVocabulary(words, makeHandles: makeHandles)
    }

    // Inject only handle construction for focused transaction failure tests.
    // The production entry point always uses the native builder above.
    func configureVocabulary(_ words: [String], makeHandles: ([String]) throws -> Handles) throws {
        let normalized = Self.normalizedWords(words)
        guard normalized != configuredWords else { return }
        let phrases = try BiasPhrases(words: normalized.map { BiasTerm(word: $0) },
                                      vocabulary: tables.vocab, strength: 8)
        let active = phrases.acceptedTerms - phrases.unspellableTerms
        let replacement: Handles
        var count = active
        do {
            replacement = try makeHandles(active == 0 ? [] : normalized)
        } catch VocabularyConfigurationError.capacityExceeded {
            // A valid but unsupported list must not disable ordinary dictation.
            // Only native automaton capacity is recoverable here; decoder asset
            // validation, allocation, and clone failures still propagate.
            replacement = try makeHandles([])
            count = 0
        }
        handles = replacement
        activeVocabularyCount = count
        configuredWords = normalized
    }

    private func makeHandles(words: [String]) throws -> Handles {
        try Self.build(tables: tables, words: words, workerCount: workerCount,
                       workerThreads: workerThreads, fastThreads: fastThreads, selective: selective,
                       checkCancellation: checkCancellation)
    }

    private static func build(tables: DecoderTables, words: [String], workerCount: Int,
                              workerThreads: Int32, fastThreads: Int32, selective: Bool = true,
                              checkCancellation: (() throws -> Void)?) throws -> Handles {
        func decoder(threads: Int32) throws -> TDTDecoder {
            // Selected, frozen compact/context configuration. The ordinary
            // empty-vocabulary path delegates to the original compiled decoder.
            try TDTDecoder(tables: tables, threads: threads,
                           hotwords: words.map { BiasTerm(word: $0) }, strength: 8,
                           selective: selective, localMargin: 8,
                           checkCancellation: checkCancellation, contextMode: 2,
                           contextMaxLoss: 8, contextWeight: 16, predictorCacheEnabled: true)
        }
        var workers: [TDTDecoder] = []
        for _ in 0..<workerCount { workers.append(try decoder(threads: workerThreads)) }
        return try Handles(workers: workers, fast: decoder(threads: fastThreads))
    }
}
