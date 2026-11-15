import SwiftUI

struct OneBotTestPanel: View {
    @Environment(AppStore.self) private var store
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        SectionCard(title: "OneBot 运行与检查", subtitle: "单独启动 bridge 不会开启自动回复；修改连接参数后重新连接。", symbol: "network") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.settings.onebot.host):\(store.settings.onebot.port) · \(store.hookStatus.bridgeRunning ? "内置 bridge 运行中" : "内置 bridge 未运行")")
                    .font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("检查连接") { perform { try await OneBotDiagnostics.check(store.settings.onebot) } }
                    Button("单独启动 bridge") {
                        perform { try await store.startDiagnosticBridge(); return "已启动 bridge，可检查连接或手动发送。" }
                    }.disabled(store.isBotRunning || store.isBotTransitioning)
                    Button("停止 bridge") {
                        perform { try store.stopDiagnosticBridge(); return "已停止内置 bridge。" }
                    }.disabled(store.isBotRunning || store.isBotTransitioning || !store.hookStatus.bridgeRunning)
                    if busy { ProgressView().controlSize(.small) }
                }.disabled(busy)
                if let result { Text(result).font(.caption).foregroundStyle(failed ? Theme.danger : Theme.success).textSelection(.enabled) }
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> String) {
        busy = true; result = nil
        Task { @MainActor in
            defer { busy = false }
            do { result = try await operation(); failed = false }
            catch { result = error.localizedDescription; failed = true }
        }
    }
}

struct ManualSendTestPanel: View {
    @Environment(AppStore.self) private var store
    @State private var target = ""
    @State private var content = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        SectionCard(title: "指定 wxid 手动发送", subtitle: "通过当前 OneBot 配置真实发送一条文字，无需启动自动回复。", symbol: "paperplane") {
            VStack(alignment: .leading, spacing: 12) {
                FormField(label: "目标 wxid / 群 ID", hint: "例如 wxid_xxx；群聊使用以 @chatroom 结尾的 ID。") {
                    TextField("wxid_xxx", text: $target)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("手动发送目标")
                }
                FormField(label: "消息正文") {
                    TextField("输入测试消息", text: $content, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityLabel("手动发送正文")
                }
                HStack {
                    Text("点击发送即发送一次；不经过 AI、名单或演练模式。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("发送一条测试消息") { send() }
                        .compatibleProminentButton()
                        .disabled(busy || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let result { Text(result).font(.caption).foregroundStyle(failed ? Theme.danger : Theme.success).textSelection(.enabled) }
            }.disabled(busy)
        }
    }

    private func send() {
        let settings = store.settings.onebot, target = target, text = content
        busy = true; result = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await OneBotDiagnostics.send(settings: settings, target: target, text: text)
                result = "bridge 已接受发送至 \(target) 的任务，请在微信确认收件。"
                failed = false
            } catch { result = error.localizedDescription; failed = true }
        }
    }
}
