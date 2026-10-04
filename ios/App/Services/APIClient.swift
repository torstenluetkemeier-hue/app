import Foundation

enum APIError: LocalizedError {
    case server(status: Int, code: String, message: String, body: Data)
    case network(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .server(_, _, message, _): message
        case .network: "Keine Verbindung zum Server. Bitte Internetverbindung prüfen."
        case .invalidResponse: "Unerwartete Antwort vom Server."
        }
    }

    var status: Int? {
        if case let .server(status, _, _, _) = self { return status }
        return nil
    }
}

private struct ServerErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }
    let error: Detail
}

/// Dünner JSON-Client für den Wochenleicht-Server.
struct APIClient: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    static func fromInfoPlist() -> APIClient {
        let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String ?? ""
        let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:8080")!
        return APIClient(baseURL: url)
    }

    func data(_ method: String, _ path: String, body: Data? = nil, token: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            throw APIError.server(status: http.statusCode, code: detail?.error.code ?? "http_\(http.statusCode)",
                                  message: detail?.error.message ?? "Serverfehler (\(http.statusCode)).", body: data)
        }
        return data
    }

    func send<Response: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil,
                                   token: String? = nil, encoder: JSONEncoder = JSONEncoder(),
                                   decoder: JSONDecoder = JSONDecoder()) async throws -> Response {
        let payload = try body.map { try encoder.encode($0) }
        let data = try await data(method, path, body: payload, token: token)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
