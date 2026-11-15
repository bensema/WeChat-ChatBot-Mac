import Foundation
@testable import WeChatAI

enum CheckFailure: Error { case failed(String) }
func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
    if try !value() { throw CheckFailure.failed(description) }
}

@main
struct InteractionContracts {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!
        let base = "http://127.0.0.1:\(port)"
        var provider = AIProvider(name: "contract", kind: .custom, baseURL: base + "/v1", model: "test-model")
        let oldData = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(AIProvider.self, from: oldData)
        try require(decoded.apiStyle == nil && decoded.reasoningEffort == nil, "legacy channel defaults")

        for effort in AIReasoningEffort.allCases {
            provider.reasoningEffort = effort
            let body = try JSONSerialization.jsonObject(with: AIClient.requestBody(messages: [.user("hi")], provider: provider, stream: false)) as! [String: Any]
            try require(body["reasoning_effort"] as? String == effort.rawValue, "chat effort \(effort)")
            try require(body["max_tokens"] == nil && body["max_completion_tokens"] as? Int == 800, "reasoning budget")
            let roundtrip = try JSONDecoder().decode(AIProvider.self, from: JSONEncoder().encode(provider))
            try require(roundtrip.reasoningEffort == effort, "effort persistence")
        }
        provider.reasoningEffort = .max
        provider.apiStyle = .responses
        provider.baseURL = base + "/v1/chat/completions/"
        try require(try AIClient.endpoint(for: provider).absoluteString == base + "/v1/responses", "switch API endpoint suffix")
        let body = try JSONSerialization.jsonObject(with: AIClient.requestBody(messages: [.user("look", images: ["https://example.test/image.png"]), .assistant("hi")], provider: provider, stream: true)) as! [String: Any]
        try require(body["messages"] == nil && body["max_tokens"] == nil, "Responses excludes chat fields")
        try require((body["reasoning"] as? [String: String])?["effort"] == "max", "Responses effort")
        try require(body["store"] as? Bool == false, "no server conversation storage")
        let input = body["input"] as! [[String: Any]]
        try require((input[0]["content"] as! [[String: Any]])[1]["type"] as? String == "input_image", "Responses image encoding")
        try require((input[1]["content"] as! [[String: Any]])[0]["type"] as? String == "output_text", "Responses assistant history")
        provider.baseURL = base + "/v1"

        let client = AIClient()
        for style in AIAPIStyle.allCases {
            provider.apiStyle = style
            for stream in [false, true] {
                let result = try await client.complete(messages: [.user("hello")], provider: provider, forceStream: stream)
                try require(result.text == "模拟回复 hello", "\(style) stream=\(stream) text")
                try require(result.usage.totalTokens == 12, "\(style) usage")
            }
        }
        provider.apiStyle = .responses
        provider.model = "fail"
        do {
            _ = try await client.complete(messages: [.user("hello")], provider: provider, forceStream: true)
            throw CheckFailure.failed("Responses failed event accepted")
        } catch let error as AIError {
            try require(error.localizedDescription.contains("expected failure"), "Responses failed event detail")
        }
        provider.model = "slow"
        let pendingProvider = provider
        let pending = Task { try await client.complete(messages: [.user("hello")], provider: pendingProvider, forceStream: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        pending.cancel()
        do { _ = try await pending.value; throw CheckFailure.failed("cancelled request succeeded") }
        catch is CheckFailure { throw CheckFailure.failed("cancelled request succeeded") }
        catch { /* URLSession must terminate the cancelled request. */ }

        var settings = OneBotSettings()
        settings.host = "127.0.0.1"; settings.port = port; settings.token = "test-only-token"
        let status = try await OneBotDiagnostics.check(settings)
        try require(status.contains("已就绪") && status.contains("可用"), "OneBot health")
        _ = try await OneBotDiagnostics.send(settings: settings, target: "wxid_xxx", text: "local fixture only")
        _ = try await OneBotDiagnostics.send(settings: settings, target: "test@chatroom", text: "local fixture only")
        settings.token = "wrong"
        do { _ = try await OneBotDiagnostics.check(settings); throw CheckFailure.failed("wrong token accepted") }
        catch is CheckFailure { throw CheckFailure.failed("wrong token accepted") }
        catch { }
        settings.host = "http://localhost/path"
        do { _ = try OneBotDiagnostics.configuration(settings); throw CheckFailure.failed("invalid host accepted") }
        catch is CheckFailure { throw CheckFailure.failed("invalid host accepted") }
        catch { }
        let ipv6 = OneBotClient.Configuration(host: "::1", port: port)
        try require(ipv6.httpBaseURL?.absoluteString == "http://[::1]:\(port)", "IPv6 URL")
        print("PASS: old settings, effort persistence, both AI protocols/streams, failure, cancellation, OneBot auth/send/IPv6")
    }
}
