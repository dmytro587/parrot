import CNeedle
import Darwin
import Foundation

/// Serializes access to the process-global Needle C API (not thread-safe).
package actor NeedleRuntime {
    static let shared = NeedleRuntime()

    private var loadedArtifactPath: String?

    func loadIfNeeded(at url: URL) throws {
        let path = url.path
        if loadedArtifactPath == path { return }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let code: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return needle_load(base, UInt64(data.count))
        }
        guard code >= 0 else {
            let message = String(cString: needle_last_error())
            throw TranscriberError.needle(
                message.isEmpty ? "needle_load failed (\(code))" : message)
        }
        loadedArtifactPath = path
    }

    func transcribe(
        pcm: [Float],
        language: String?,
        keywords: String?
    ) throws -> NeedleTranscription {
        let capacity = 65_536
        var buffer = [CChar](repeating: 0, count: capacity)

        let tokens: Int32 = pcm.withUnsafeBufferPointer { ptr in
            Self.callTranscribe(
                pcm: ptr.baseAddress,
                samples: Int32(ptr.count),
                language: language,
                keywords: keywords,
                buffer: &buffer,
                capacity: Int32(capacity)
            )
        }
        guard tokens >= 0 else {
            let message = String(cString: needle_last_error())
            throw TranscriberError.needle(
                message.isEmpty ? "needle_transcribe failed (\(tokens))" : message)
        }
        let json = String(cString: buffer)
        guard let data = json.data(using: .utf8) else {
            throw TranscriberError.needle("invalid UTF-8 from needle")
        }
        return try JSONDecoder().decode(NeedleTranscription.self, from: data)
    }

    private static func callTranscribe(
        pcm: UnsafePointer<Float>?,
        samples: Int32,
        language: String?,
        keywords: String?,
        buffer: UnsafeMutablePointer<CChar>,
        capacity: Int32
    ) -> Int32 {
        switch (language, keywords) {
        case (nil, nil):
            return needle_transcribe(pcm, samples, nil, nil, 0, buffer, capacity)
        case (let lang?, nil):
            return lang.withCString {
                needle_transcribe(pcm, samples, $0, nil, 0, buffer, capacity)
            }
        case (nil, let kw?):
            return kw.withCString {
                needle_transcribe(pcm, samples, nil, $0, 0, buffer, capacity)
            }
        case (let lang?, let kw?):
            return lang.withCString { langPtr in
                kw.withCString {
                    needle_transcribe(pcm, samples, langPtr, $0, 0, buffer, capacity)
                }
            }
        }
    }
}

struct NeedleTranscription: Decodable {
    var text: String
    var language: String?
    var ttft_ms: Double?
    var decode_tps: Double?
}
