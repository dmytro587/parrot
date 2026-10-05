import Foundation

package protocol PhononAdapter: Sendable {
    func checkHealth() async throws
    func transcribe(samples: [Float], sampleRate: Double, hotwords: String?) async throws -> String
}

package final class PhononHTTPAdapter: PhononAdapter, @unchecked Sendable {
    private let configuration: PhononConfiguration
    private let session: URLSession
    private let redirectDelegate: RedirectBlockingDelegate?

    package init(configuration: PhononConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
            self.redirectDelegate = nil
        } else {
            let production = Self.makeProductionSession()
            self.redirectDelegate = production.redirectDelegate
            self.session = production.session
        }
    }

    private static func makeProductionSession() -> (
        session: URLSession, redirectDelegate: RedirectBlockingDelegate
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let redirectDelegate = RedirectBlockingDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        return (session, redirectDelegate)
    }

    package func checkHealth() async throws {
        var request = URLRequest(url: endpoint("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.startupTimeout
        authorize(&request)
        let (data, response) = try await perform(request, operation: "checking readiness")
        try validate(status: response.statusCode, data: data)
        guard
            let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
            health.status == "ok"
        else {
            throw PhononError.malformedHealth
        }
    }

    package func transcribe(
        samples: [Float],
        sampleRate: Double,
        hotwords: String?
    ) async throws -> String {
        let maximumSamples = (configuration.maximumWAVBytes - 44) / 2
        guard samples.count <= maximumSamples else {
            throw PhononError.audioTooLarge(limit: configuration.maximumWAVBytes)
        }
        let wav = WAVEncoder.data(samples: samples, sampleRate: Int(sampleRate.rounded()))
        guard wav.count <= configuration.maximumWAVBytes else {
            throw PhononError.audioTooLarge(limit: configuration.maximumWAVBytes)
        }

        let boundary = "Parrot-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.transcriptionTimeout
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = multipartBody(wav: wav, hotwords: hotwords, boundary: boundary)

        let (data, response) = try await perform(request, operation: "transcribing")
        try validate(status: response.statusCode, data: data)
        guard let transcription = try? JSONDecoder().decode(TranscriptionResponse.self, from: data)
        else {
            throw PhononError.malformedResponse
        }
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func authorize(_ request: inout URLRequest) {
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(
        _ request: URLRequest,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw PhononError.unexpectedResponse
            }
            return (data, response)
        } catch let error as PhononError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw PhononError.timeout(operation)
            }
            throw PhononError.connection(operation)
        } catch {
            throw PhononError.connection(operation)
        }
    }

    private func validate(status: Int, data: Data) throws {
        guard status == 200 else {
            if (300...399).contains(status) { throw PhononError.redirect(status: status) }
            if status == 401 || status == 403 { throw PhononError.unauthorized }
            let upstream = (try? JSONDecoder().decode(UpstreamError.self, from: data))?.error
            let type = Self.sanitizedField(upstream?.type, maximumBytes: 80)
            let message = Self.sanitizedField(upstream?.message, maximumBytes: 240)
            if (400...499).contains(status) {
                throw PhononError.clientFailure(status: status, type: type, message: message)
            }
            throw PhononError.serverFailure(status: status, type: type, message: message)
        }
    }

    private static func sanitizedField(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        var withoutControls = ""
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            withoutControls.unicodeScalars.append(scalar)
        }
        let normalized = withoutControls.split(whereSeparator: { $0.isWhitespace }).joined(
            separator: " ")
        guard !normalized.isEmpty else { return nil }

        guard normalized.utf8.count > maximumBytes else { return normalized }
        var truncated = ""
        for scalar in normalized.unicodeScalars {
            let next = String(scalar)
            guard truncated.utf8.count + next.utf8.count <= maximumBytes - 3 else { break }
            truncated.append(contentsOf: next)
        }
        return "\(truncated)..."
    }

    private func multipartBody(wav: Data, hotwords: String?, boundary: String) -> Data {
        var body = Data()
        appendField("model", value: configuration.modelID, boundary: boundary, to: &body)
        appendField("response_format", value: "json", boundary: boundary, to: &body)
        if let hotwords, !hotwords.isEmpty {
            appendField("hotwords", value: hotwords, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(
                using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func appendField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct HealthResponse: Decodable {
    let status: String
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct UpstreamError: Decodable {
    struct Detail: Decodable {
        let message: String?
        let type: String?
    }

    let error: Detail?
}
