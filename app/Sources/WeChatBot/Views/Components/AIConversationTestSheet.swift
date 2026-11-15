import SwiftUI

/// A channel playground with conversation history, cancellation and visible responses.
struct AIConversationTestSheet: View {
    let provider: AIProvider
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AIMessage] = []
    @State private var prompt = "你好，请介绍一下你自己。"
    @State private var response = ""
    @State private var detail = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("AI 对话测试 · \(provider.name)").font(.headline)
                    Text("\(provider.model) · \(provider.apiStyle?.label ?? AIAPIStyle.chatCompletions.label) · effort \(provider.reasoningEffort?.rawValue ?? "默认")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("使用已保存的通道设置和密钥；测试内容只发送给此 AI 服务，不发往微信。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "你" : "AI").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !response.isEmpty { Text(response).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if !detail.isEmpty { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            TextEditor(text: $prompt).font(.body).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline).allowsHitTesting(false))
                .accessibilityLabel("AI 测试输入")
                .disabled(task != nil)
            HStack {
                Button("清空对话") { messages = []; response = ""; detail = ""; error = nil }.disabled(task != nil)
                Spacer()
                if task != nil {
                    ProgressView().controlSize(.small)
                    Button("取消请求") { task?.cancel() }
                }
                Button("发送测试") { send() }
                    .compatibleProminentButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(task != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 680, height: 620)
        .onDisappear { requestID = UUID(); task?.cancel() }
    }

    private func send() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = messages + [.user(input)]
        error = nil; detail = ""; response = ""
        let id = UUID()
        requestID = id
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await AIClient().complete(messages: history, provider: provider,
                    temperature: provider.requestTemperature, forceStream: provider.stream,
                    onDelta: { delta in Task { @MainActor in
                        guard requestID == id else { return }
                        response += delta
                    } })
                try Task.checkCancellation()
                requestID = UUID()
                messages = history + [.assistant(result.text)]
                response = ""; prompt = ""
                detail = "\(result.model) · \(Int(result.latencyMs)) ms · \(result.usage.totalTokens) tokens"
            } catch {
                requestID = UUID()
                response = ""
                self.error = Task.isCancelled ? "请求已取消，可修改输入后重试。" : error.localizedDescription
            }
        }
    }
}
