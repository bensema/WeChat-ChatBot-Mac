import Foundation

enum OneBotDiagnostics {
    static func configuration(_ settings: OneBotSettings) throws -> OneBotClient.Configuration {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains("?"),
              !host.contains("#"), !host.contains(where: { $0.isWhitespace }),
              (1...65535).contains(settings.port) else {
            throw OneBotError.invalidURL("请填写有效 Host 和 1–65535 端口；Host 不包含协议或路径。")
        }
        guard !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OneBotError.sendFailed("请先配置 OneBot Token，或启动内置 bridge 自动生成。")
        }
        return OneBotClient.Configuration(host: host, port: settings.port, token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func check(_ settings: OneBotSettings) async throws -> String {
        let config = try configuration(settings)
        guard let base = config.httpBaseURL else { throw OneBotError.invalidURL(config.host) }
        var request = try OneBotClient.voiceStatusRequest(baseURL: base, token: config.token)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OneBotError.badResponse("连接检查失败（HTTP \(code)）；请检查端口和 Token。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true,
              let hook = object["hook"] as? [String: Any] else {
            throw OneBotError.badResponse("bridge 可连接，但 Hook 未就绪。")
        }
        let ready = hook["ready"] as? Bool
        let send = hook["sendSupported"] as? Bool
        if ready == false { throw OneBotError.badResponse("bridge 鉴权通过，但 Hook 尚未就绪。") }
        return "HTTP 鉴权通过 · Hook \(ready.map { $0 ? "已就绪" : "未就绪" } ?? "已响应")" +
            (send.map { " · 文字发送\($0 ? "可用" : "不可用")" } ?? "")
    }

    static func send(settings: OneBotSettings, target: String, text: String) async throws -> String {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains(where: { $0.isWhitespace }), !text.isEmpty else {
            throw OneBotError.sendFailed("请填写一个有效会话 ID 和消息正文。")
        }
        let client = OneBotClient(configuration: try configuration(settings))
        return try await client.sendText(conversationID: target, isGroup: target.lowercased().hasSuffix("@chatroom"), text: text)
    }
}
