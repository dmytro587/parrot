import Foundation

/// Loopback HTTP settings for Phonon (Parrot-owned `fermion serve` or an external server).
package struct PhononConfiguration {
    /// Fermion caps upload bodies at 32 MiB.
    package static let defaultMaximumWAVBytes = 32 * 1024 * 1024

    let baseURL: URL
    let modelID: String
    let apiKey: String?
    let startupTimeout: TimeInterval
    let transcriptionTimeout: TimeInterval
    let maximumWAVBytes: Int

    package init(
        urlString: String,
        modelID: String,
        apiKey: String? = nil,
        startupTimeout: TimeInterval = 120,
        transcriptionTimeout: TimeInterval = 120,
        maximumWAVBytes: Int = PhononConfiguration.defaultMaximumWAVBytes
    ) throws {
        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(),
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
            let port = components.port,
            (1...65_535).contains(port),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let baseURL = components.url
        else {
            throw PhononError.invalidEndpoint
        }

        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        self.startupTimeout = startupTimeout
        self.transcriptionTimeout = transcriptionTimeout
        self.maximumWAVBytes = maximumWAVBytes
    }
}

/// Optional override for an external loopback server (advanced).
package enum PhononRuntime {
    package private(set) static var apiKey: String?

    package static func apply(url: String?) {
        PhononServer.externalServiceURL = url?.isEmpty == false ? url : nil
        apiKey = ProcessInfo.processInfo.environment["PARROT_PHONON_API_KEY"]
    }
}

package enum PhononError: LocalizedError, CustomStringConvertible {
    case invalidEndpoint
    case connection(String)
    case timeout(String)
    case unauthorized
    case redirect(status: Int)
    case clientFailure(status: Int, type: String?, message: String?)
    case serverFailure(status: Int, type: String?, message: String?)
    case malformedHealth
    case malformedResponse
    case unexpectedResponse
    case audioTooLarge(limit: Int)
    case weightsMissing(String)

    package var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Phonon URL must be an HTTP(S) loopback URL with an explicit port."
        case .connection(let operation):
            return "Could not reach the local Phonon service while \(operation)."
        case .timeout(let operation):
            return "The local Phonon service timed out while \(operation)."
        case .unauthorized:
            return "Phonon rejected the API key; check PARROT_PHONON_API_KEY."
        case .redirect(let status):
            return "Phonon redirected a local request (HTTP \(status)); redirects are blocked."
        case .clientFailure(let status, let type, let message):
            return Self.failureDescription("Phonon rejected the request", status, type, message)
        case .serverFailure(let status, let type, let message):
            return Self.failureDescription("Phonon service failed", status, type, message)
        case .malformedHealth:
            return "Phonon health response was invalid; expected {\"status\":\"ok\"}."
        case .malformedResponse:
            return "Phonon transcription response was invalid; expected JSON with a text field."
        case .unexpectedResponse:
            return "Phonon returned a non-HTTP response."
        case .audioTooLarge(let limit):
            return "Captured audio exceeds Phonon's \(limit / 1024 / 1024) MiB upload limit."
        case .weightsMissing(let message):
            return message
        }
    }

    package var description: String {
        errorDescription ?? "Phonon service error."
    }

    private static func failureDescription(
        _ prefix: String,
        _ status: Int,
        _ type: String?,
        _ message: String?
    ) -> String {
        let detail = type.map { ", \($0)" } ?? ""
        let base = "\(prefix) (HTTP \(status)\(detail))"
        return message.map { "\(base): \($0)" } ?? "\(base)."
    }
}
