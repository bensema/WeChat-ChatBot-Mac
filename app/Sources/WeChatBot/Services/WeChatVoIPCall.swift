import Foundation

/// Parsed WeChat VoIP call log stored as a `voipmsg` text message.
struct WeChatVoIPCall: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case duration(Int)
        case message(String)
        case unknown
    }

    var result: Result

    var summary: String {
        switch result {
        case .duration(let seconds):
            return "通话时长 \(Self.formatDuration(seconds))"
        case .message(let text):
            return text
        case .unknown:
            return "语音通话"
        }
    }

    /// Accepts either the message body or an event's raw JSON. The XML may be
    /// entity-escaped by old bridge versions, so decode before checking tags.
    static func parse(_ value: String?) -> WeChatVoIPCall? {
        guard let value,
              value.range(of: "voipmsg", options: .caseInsensitive) != nil else { return nil }
        let decoded = WeChatXML.decodeEscapes(value)
        let xml = WeChatXML.unescape(decoded)
        let lowercased = xml.lowercased()
        guard lowercased.contains("<voipmsg"),
              lowercased.contains("bubblemsg"),
              let body = WeChatXML.block("voipmsg", in: xml) else {
            return nil
        }

        let payload = WeChatXML.block("VoIPBubbleMsg", in: body) ?? body
        let duration = Int(WeChatXML.field("duration", in: payload) ?? "")
        let message = WeChatXML.field("msg", in: payload)
            .map(stripMessageWrapper)
            .flatMap { $0.isEmpty ? nil : $0 }

        if let duration, duration > 0 {
            return WeChatVoIPCall(result: .duration(duration))
        }
        if let message {
            return WeChatVoIPCall(result: .message(message))
        }
        return WeChatVoIPCall(result: .unknown)
    }

    private static func stripMessageWrapper(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "[", trimmed.last == "]" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
