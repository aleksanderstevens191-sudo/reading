import Foundation
import Metal
#if canImport(llama)
import llama
#endif

enum LLMError: LocalizedError {
    case noModel, loadFailed, unavailable, decodeFailed
    var errorDescription: String? {
        switch self {
        case .noModel: return "The AI model file isn’t on this device yet."
        case .loadFailed: return "Couldn’t load the AI model."
        case .unavailable: return "The AI only runs on a real iPad or iPhone, not the simulator."
        case .decodeFailed: return "The AI stopped unexpectedly."
        }
    }
}

struct LLMStats: Sendable {
    var promptTokens = 0        // tokens that actually had to be read (after cache reuse)
    var reusedTokens = 0        // tokens reused from the previous request
    var promptSeconds = 0.0
    var outputTokens = 0
    var outputSeconds = 0.0
    var tokensPerSecond: Double { outputSeconds > 0 ? Double(outputTokens) / outputSeconds : 0 }
}

/// One message in a Gemma conversation. Role is "system", "user" or "model".
struct Turn: Sendable, Equatable {
    var role: String
    var text: String
}

/// Thread-safe stop flag shared between the UI and the generation loop.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Lets llama.cpp check the current stop flag in the middle of reading a long prompt.
private final class AbortBox: @unchecked Sendable {
    var flag: StopFlag?
}

/// Runs Gemma 4 E2B fully on-device with llama.cpp.
///
/// Keeps whatever it has already read in memory: if the next request starts
/// with the same text (the instructions and the "story so far"), only the new
/// part is read. That makes questions about the same book much faster.
actor LocalLLM {
    static let shared = LocalLLM()

    /// Looks for a .gguf model in Documents/Models, Documents, then the app bundle.
    nonisolated static func findModel() -> URL? {
        if let p = ProcessInfo.processInfo.environment["READING_MODEL"] { return URL(fileURLWithPath: p) }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for dir in [docs.appendingPathComponent("Models"), docs] {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               let m = items.filter({ $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.hasPrefix("mtp-") && !$0.lastPathComponent.hasPrefix("mmproj") })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return m
            }
        }
        if let urls = Bundle.main.urls(forResourcesWithExtension: "gguf", subdirectory: nil), let m = urls.first { return m }
        return nil
    }

    nonisolated static var isAvailable: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// Performance-core count, used while writing an answer.
    nonisolated static var threadCount: Int32 {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return min(n, 6) }
        return Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    /// Threads for reading a prompt (compute-bound, so extra cores help).
    nonisolated static var batchThreadCount: Int32 {
        if let s = ProcessInfo.processInfo.environment["READING_BATCH_THREADS"], let n = Int32(s) { return n }
        // Measured on the A12Z: all 8 cores read a page ~20% faster than the 4 fast ones.
        return Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
    }

    /// Older GPUs (A12/A13 = Metal "Apple5/6") lack the features llama.cpp's GPU path needs.
    nonisolated static var gpuUsable: Bool {
        if ProcessInfo.processInfo.environment["READING_CPU_ONLY"] != nil { return false }
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
    }

    static let contextSize = 6144

    private(set) var loaded = false
    private(set) var modelName = ""
    var debugCachedCount: Int {
        #if canImport(llama)
        return cached.count
        #else
        return 0
        #endif
    }

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var cpuDevices: [ggml_backend_dev_t?] = []
    private var cached: [llama_token] = []       // exactly what's in the model's memory right now
    private let abortBox = AbortBox()
    #endif

    func load() throws {
        #if canImport(llama)
        if loaded { return }
        guard let url = Self.findModel() else { throw LLMError.noModel }
        // On GPUs llama.cpp can't use (A12Z etc.) skip Metal setup entirely: it only
        // costs seconds of shader compiling and memory.
        if !Self.gpuUsable { setenv("GGML_METAL_DEVICES", "0", 1) }
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil) // keep the console quiet

        var mp = llama_model_default_params()
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        // Gemma's large per-layer embedding table is read row-by-row on demand,
        // which keeps memory use low on a 6 GB iPad.
        mp.lazy_mode = LLAMA_LAZY_MODE_ON
        let useGPU = Self.gpuUsable
        mp.n_gpu_layers = useGPU ? 999 : 0
        if !useGPU, let cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) {
            cpuDevices = [cpu, nil]
        }
        let m: OpaquePointer? = cpuDevices.isEmpty
            ? llama_model_load_from_file(url.path, mp)
            : cpuDevices.withUnsafeMutableBufferPointer { buf -> OpaquePointer? in
                mp.devices = buf.baseAddress
                return llama_model_load_from_file(url.path, mp)
            }
        guard let m else { throw LLMError.loadFailed }

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(Self.contextSize)
        cp.n_batch = 256
        cp.n_ubatch = 256
        cp.n_threads = Self.threadCount
        cp.n_threads_batch = Self.batchThreadCount
        cp.op_offload = useGPU
        cp.offload_kqv = useGPU
        cp.swa_full = true   // lets us keep a shared start of the prompt and drop the rest
        cp.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().flag?.value ?? false
        }
        cp.abort_callback_data = Unmanaged.passUnretained(abortBox).toOpaque()
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw LLMError.loadFailed
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        modelName = url.deletingPathExtension().lastPathComponent
        loaded = true
        #else
        throw LLMError.unavailable
        #endif
    }

    /// Gemma 4 chat format.
    nonisolated static func format(_ turns: [Turn], openModelTurn: Bool = true) -> String {
        var s = ""
        for t in turns {
            s += "<|turn>\(t.role)\n\(t.text.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n"
        }
        if openModelTurn { s += "<|turn>model\n" }
        return s
    }

    /// Streams the model's reply, piece by piece.
    /// - background: use fewer cores (less heat) for work the reader isn't waiting on.
    /// - maxTokens 0: only read the prompt into memory, so the next request starts instantly.
    func generate(turns: [Turn], maxTokens: Int = 700, stop: StopFlag, background: Bool = false,
                  onToken: @Sendable (String) -> Void = { _ in }) throws -> LLMStats {
        try run(text: Self.format(turns, openModelTurn: maxTokens > 0), maxTokens: maxTokens, stop: stop,
                background: background, onToken: onToken)
    }

    /// Reads raw text into memory without answering, e.g. the start of a question
    /// about the page the reader is on, so asking it later is near-instant.
    func prime(raw: String, stop: StopFlag) throws -> LLMStats {
        try run(text: raw, maxTokens: 0, stop: stop, background: true, onToken: { _ in })
    }

    private func run(text: String, maxTokens: Int, stop: StopFlag, background: Bool,
                     onToken: @Sendable (String) -> Void) throws -> LLMStats {
        #if canImport(llama)
        try load()
        guard let ctx, let vocab else { throw LLMError.loadFailed }
        abortBox.flag = stop
        defer { abortBox.flag = nil }
        llama_set_n_threads(ctx, background ? min(4, Self.threadCount) : Self.threadCount,
                            background ? min(4, Self.batchThreadCount) : Self.batchThreadCount)
        var stats = LLMStats()

        var tokens = tokenize(text)
        let limit = Self.contextSize - maxTokens - 8
        if tokens.count > limit {
            // keep the start (instructions + context) and the end (the question)
            tokens = Array(tokens.prefix(limit / 2)) + Array(tokens.suffix(limit - limit / 2))
        }

        // Reuse whatever matching start is already in memory.
        let mem = llama_get_memory(ctx)
        var common = 0
        while common < min(cached.count, tokens.count), cached[common] == tokens[common] { common += 1 }
        if common == tokens.count, maxTokens > 0, common > 0 { common -= 1 }  // must read ≥1 token to answer
        if common < cached.count {
            if !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
                llama_memory_clear(mem, true)
                common = 0
            }
            cached = Array(cached.prefix(common))
        }
        stats.reusedTokens = common

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.05, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(64))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(background ? 0.3 : 0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        // Read the new part of the prompt
        let t0 = Date()
        var i = common
        let nBatch = Int(llama_n_batch(ctx))
        while i < tokens.count {
            if stop.value { return stats }
            let n = min(nBatch, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + i, Int32(n)))
            }
            if rc != 0 {
                syncCache(from: tokens)
                if rc == 2 || stop.value { return stats }  // stopped on purpose
                throw LLMError.decodeFailed
            }
            cached += tokens[i..<(i + n)]
            i += n
        }
        stats.promptTokens = tokens.count - common
        stats.promptSeconds = Date().timeIntervalSince(t0)
        if maxTokens == 0 { return stats }

        // Write the answer
        let t1 = Date()
        var pending: [UInt8] = []
        var inThought = false
        for _ in 0..<maxTokens {
            if stop.value { break }
            var tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            stats.outputTokens += 1

            let piece = pieceBytes(tok)
            let s = String(decoding: piece, as: UTF8.self)
            let special = piece.first == UInt8(ascii: "<") && s.hasSuffix(">") && s.count < 20
            if special {
                if s == "<|channel>" { inThought = true }
                else if s == "<channel|>" { inThought = false }
                else if s == "<turn|>" || s == "<|turn>" { break }
            } else if !inThought {
                pending += piece
                if let str = String(bytes: pending, encoding: .utf8) {
                    onToken(str); pending.removeAll()
                } else if pending.count > 8 {
                    onToken(String(decoding: pending, as: UTF8.self)); pending.removeAll()
                }
            }

            let rc = withUnsafeMutablePointer(to: &tok) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if rc != 0 { syncCache(); break }
            cached.append(tok)
        }
        stats.outputSeconds = Date().timeIntervalSince(t1)
        return stats
        #else
        throw LLMError.unavailable
        #endif
    }

    #if canImport(llama)
    /// After an interrupted read, trust only what the model actually stored.
    private func syncCache(from tokens: [llama_token]? = nil) {
        guard let ctx else { return }
        let stored = Int(llama_memory_seq_pos_max(llama_get_memory(ctx), 0)) + 1
        if let tokens, stored > cached.count, stored <= tokens.count {
            cached = Array(tokens.prefix(stored))
        } else if stored < cached.count {
            cached = Array(cached.prefix(max(0, stored)))
        }
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8Count = text.utf8.count
        var out = [llama_token](repeating: 0, count: utf8Count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8Count), &out, Int32(out.count), true, true)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8Count), &out, Int32(out.count), true, true)
        }
        return Array(out.prefix(Int(max(0, n))))
    }

    private func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }
    #endif
}
