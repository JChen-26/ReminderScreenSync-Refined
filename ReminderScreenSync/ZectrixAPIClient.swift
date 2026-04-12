import Foundation

enum ZectrixAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int)
    case apiError(code: Int, message: String?)
    case missingData

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先填写 \(AppConstants.openPlatformName) API Key。"
        case .invalidURL:
            return "\(AppConstants.openPlatformName) 接口地址无效。"
        case .httpStatus(let status):
            return "\(AppConstants.openPlatformName) HTTP 错误：\(status)。"
        case .apiError(let code, let message):
            return "\(AppConstants.openPlatformName) 返回错误 code=\(code)：\(message ?? "无错误信息")。"
        case .missingData:
            return "\(AppConstants.openPlatformName) 响应缺少 data 字段。"
        }
    }
}

final class ZectrixAPIClient {
    private let apiKey: String
    private let baseURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(apiKey: String, baseURL: URL = AppConstants.zectrixBaseURL) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
    }

    func fetchDevices() async throws -> [ScreenDevice] {
        try await get("devices", queryItems: [])
    }

    func fetchAllTodos(deviceId: String) async throws -> [ScreenTodo] {
        async let incomplete = fetchTodos(deviceId: deviceId, status: 0)
        async let completed = fetchTodos(deviceId: deviceId, status: 1)
        let combined = try await incomplete + completed

        var byId: [Int: ScreenTodo] = [:]
        for todo in combined {
            byId[todo.id] = todo
        }

        return byId.values.sorted { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    func createTodo(_ draft: ScreenTodoDraft) async throws -> ScreenTodoMutationResult {
        try await send("todos", method: "POST", body: draft)
    }

    func updateTodo(id: Int, update: ScreenTodoUpdate) async throws {
        guard !update.isEmpty else { return }
        let _: ScreenTodoMutationResult = try await send("todos/\(id)", method: "PUT", body: update)
    }

    func toggleTodoCompletion(id: Int) async throws {
        try await sendWithoutData("todos/\(id)/complete", method: "PUT")
    }

    func deleteTodo(id: Int) async throws {
        try await sendWithoutData("todos/\(id)", method: "DELETE")
    }

    private func fetchTodos(deviceId: String, status: Int) async throws -> [ScreenTodo] {
        try await get(
            "todos",
            queryItems: [
                URLQueryItem(name: "status", value: String(status)),
                URLQueryItem(name: "deviceId", value: deviceId)
            ]
        )
    }

    private func get<Response: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: "GET", queryItems: queryItems, body: nil)
        let data = try await data(for: request)
        return try decodeEnvelope(data)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        let bodyData = try encoder.encode(body)
        let request = try makeRequest(path: path, method: method, queryItems: [], body: bodyData)
        let data = try await data(for: request)
        return try decodeEnvelope(data)
    }

    private func sendWithoutData(_ path: String, method: String) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: nil)
        let data = try await data(for: request)
        let response = try decoder.decode(APIStatusResponse.self, from: data)
        guard response.code == 0 else {
            throw ZectrixAPIError.apiError(code: response.code, message: response.msg)
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ZectrixAPIError.missingAPIKey }

        let endpoint = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ZectrixAPIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ZectrixAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 20
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ZectrixAPIError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private func decodeEnvelope<Response: Decodable>(_ data: Data) throws -> Response {
        let envelope = try decoder.decode(APIResponse<Response>.self, from: data)
        guard envelope.code == 0 else {
            throw ZectrixAPIError.apiError(code: envelope.code, message: envelope.msg)
        }
        guard let payload = envelope.data else {
            throw ZectrixAPIError.missingData
        }
        return payload
    }
}
