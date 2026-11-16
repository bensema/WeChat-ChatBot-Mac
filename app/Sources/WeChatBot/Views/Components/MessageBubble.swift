import AppKit
import ImageIO
import SwiftUI

/// Chat bubble supporting text / image / voice / emoji / file / video / link,
/// timestamps and delivery / generation state.
///
/// Equatable so streaming updates to a message list don't re-evaluate unchanged
/// bubbles (`ForEach` rows use `.equatable()`); all rendered state derives from
/// `message` and `showsSender`.
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var showsSender: Bool = true
    var senderAvatarURL: URL? = nil
    /// 是否在无语音气泡里展示转写（`BotSettings.voice.showTranscriptInBubble`）。
    var voiceTranscriptVisible: Bool = true
    /// 「转写失败 · 重试」；nil 表示不可重试（如历史消息/离线查看）。
    var onRetryVoice: ((ChatMessage) -> Void)?
    var imageFetchFailed = false
    var onRetryImage: ((ChatMessage) -> Void)?
    var onFetchHighResolutionImage: (@MainActor (ChatMessage) async throws -> URL)?
    var onPreviewImage: ((ChatImagePreviewSelection) -> Void)?

    /// Loaded once per media path instead of on every body evaluation: the previous
    /// computed `NSImage(contentsOfFile:)` re-read the file from disk whenever the
    /// bubble's body ran again (e.g. once per incoming message).
    @State private var localImage: NSImage?
    /// Path that `localImage` was decoded from, so a changed path reloads.
    @State private var loadedImagePath: String?
    @State private var imagePreview: ChatImagePreviewSelection?

    /// Manual comparison: `localImage` is view-local state and must not participate.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.showsSender == rhs.showsSender
            && lhs.senderAvatarURL == rhs.senderAvatarURL
            && lhs.voiceTranscriptVisible == rhs.voiceTranscriptVisible
            && lhs.imageFetchFailed == rhs.imageFetchFailed
    }

    var body: some View {
        if let call = voipCall {
            voipCallRow(call)
        } else if message.direction == .system || message.kind == .system {
            SystemNoticeRow(message: message)
        } else {
            bubbleRow
        }
    }

    private var voipCall: WeChatVoIPCall? {
        WeChatVoIPCall.parse(message.rawJSON) ?? WeChatVoIPCall.parse(message.text)
    }

    private func voipCallRow(_ call: WeChatVoIPCall) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.isOutgoing {
                Spacer(minLength: 70)
            } else {
                AvatarView(
                    title: message.displaySender, kind: .direct, size: 26,
                    imageURL: senderAvatarURL, isRoundedSquare: true
                )
                    .padding(.bottom, 2)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsSender, !message.isOutgoing {
                    Text(message.displaySender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
                HStack(spacing: 8) {
                    Image(systemName: callSymbol(call))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(callTint(call))
                        .frame(width: 20, height: 20)
                        .background(callTint(call).opacity(0.12), in: Circle())
                    Text(call.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(minWidth: 118, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(message.isOutgoing ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(message.isOutgoing ? Theme.accent.opacity(0.18) : Theme.hairline, lineWidth: 1)
                }
                footer
            }

            if !message.isOutgoing {
                Spacer(minLength: 70)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(call: call))
        .contextMenu {
            Button(L("复制通话记录")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(call.summary, forType: .string)
            }
            Button(L("复制消息 ID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.id, forType: .string)
            }
        }
    }

    private func callSymbol(_ call: WeChatVoIPCall) -> String {
        switch call.result {
        case .duration:
            message.isOutgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
        case .message(let text) where text.localizedCaseInsensitiveContains("取消") || text.localizedCaseInsensitiveContains("未接"):
            "phone.down.fill"
        case .message, .unknown:
            message.isOutgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
        }
    }

    private func callTint(_ call: WeChatVoIPCall) -> Color {
        if case .message(let text) = call.result,
           text.localizedCaseInsensitiveContains("取消") || text.localizedCaseInsensitiveContains("未接") {
            return Theme.warning
        }
        return Theme.accent
    }

    // MARK: Bubble

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.isOutgoing {
                Spacer(minLength: 70)
            } else {
                AvatarView(
                    title: message.displaySender, kind: .direct, size: 26,
                    imageURL: senderAvatarURL, isRoundedSquare: true
                )
                    .padding(.bottom, 2)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsSender, !message.isOutgoing {
                    Text(message.displaySender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
                bubble
                footer
            }

            if !message.isOutgoing {
                Spacer(minLength: 70)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var bubble: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
            .background {
                shape
                    .fill(backgroundStyle)
            }
            .overlay {
                shape
                    .strokeBorder(
                        message.isOutgoing ? Color.white.opacity(0.16) : Theme.hairline,
                        lineWidth: 1
                    )
            }
            .contextMenu {
                if !message.text.isEmpty {
                    Button(L("复制文本")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
                if message.kind == .image, let description = imageDescription {
                    Button(L("复制识图描述")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(description, forType: .string)
                    }
                }
                if message.kind == .image, let path = message.mediaPath, !path.isEmpty {
                    Button(L("保存图片…")) {
                        saveImage(atPath: path)
                    }
                } else if message.kind == .image, let remoteImageURL {
                    Button(L("保存图片…")) {
                        saveImage(from: remoteImageURL)
                    }
                }
                if let imageURL = finderFeed?.imageURL {
                    Button(L("保存封面…")) {
                        saveImage(from: imageURL)
                    }
                }
                if message.kind == .voice, let transcript = voiceTranscript {
                    Button(L("复制语音转写")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }
                }
                Button(L("复制消息 ID")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.id, forType: .string)
                }
            }
    }

    private func openImagePreview(
        _ url: URL,
        title: String,
        loadOriginal: (@MainActor () async throws -> URL)? = nil
    ) {
        let selection = ChatImagePreviewSelection(url: url, title: title, loadOriginal: loadOriginal)
        if let onPreviewImage {
            onPreviewImage(selection)
        } else {
            imagePreview = selection
        }
    }

    private var loadHighResolutionImage: (@MainActor () async throws -> URL)? {
        guard let onFetchHighResolutionImage,
              message.kind == .image,
              message.id.hasPrefix("ob-"),
              let xml = rawImageXML,
              xml.range(of: "<img", options: .caseInsensitive) != nil,
              (xml.range(of: "cdnhdurl=", options: .caseInsensitive) != nil
                || xml.range(of: "cdnmidimgurl=", options: .caseInsensitive) != nil),
              xml.range(of: "aeskey=", options: .caseInsensitive) != nil
        else { return nil }
        return { try await onFetchHighResolutionImage(message) }
    }

    private var rawImageXML: String? {
        guard let rawJSON = message.rawJSON,
              let data = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return message.rawJSON?.hasPrefix("<") == true ? message.rawJSON : nil }
        if let raw = root["raw_message"] as? String ?? root["rawMessage"] as? String {
            return raw
        }
        if let nested = root["data"] as? [String: Any] {
            return nested["raw_message"] as? String ?? nested["rawMessage"] as? String
        }
        return nil
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
    }

    private var backgroundStyle: AnyShapeStyle {
        if message.isOutgoing {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.96), Theme.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(.regularMaterial)
    }

    // MARK: Content by kind

    private var content: some View {
        Group {
            if message.status == .generating, message.text.isEmpty {
                TypingIndicator(tint: message.isOutgoing ? .white : Theme.accent)
                    .padding(.vertical, 2)
            } else {
                switch message.kind {
                case .text:
                    if let finderFeed {
                        finderFeedContent(feed: finderFeed)
                    } else {
                        Text(message.text.isEmpty ? " " : message.text)
                            .font(.body)
                            .lineSpacing(3)
                    }
                case .image:
                    imageContent
                case .voice:
                    voiceContent
                case .emoji:
                    Text(message.text.isEmpty ? "🙂" : message.text)
                        .font(.system(size: 34))
                case .file:
                    fileContent
                case .video:
                    videoContent
                case .link:
                    linkContent
                case .system:
                    Text(message.text).font(.caption)
                }
            }
        }
    }

    /// Loads the local media file once per path (`.task(id:)`), never during body
    /// evaluation. Previously every body re-run re-read the file from disk.
    ///
    /// 解码放到后台线程并按最长边 1600px 下采样：12MP HEIC 在主线程解码
    /// 会让会话列表滚动/首次显示卡 50–300ms，原图整张常驻内存也浪费。
    private func loadLocalImageIfNeeded() async {
        guard let path = message.mediaPath, !path.isEmpty else {
            localImage = nil
            loadedImagePath = nil
            return
        }
        guard loadedImagePath != path else { return }
        loadedImagePath = path
        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeDownsampledImage(atPath: path)
        }.value
        guard !Task.isCancelled else { return }
        localImage = image
    }

    /// 后台解码 + 下采样（最长边 1600px，足够 2x/3x 气泡显示）。
    private nonisolated static func decodeDownsampledImage(atPath path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private var remoteImageURL: URL? {
        guard let string = message.mediaURL,
              let url = URL(string: string),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            imageContentBody
            if let description = imageDescription {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "eye")
                        .font(.system(size: 9, weight: .medium))
                    Text(description)
                        .font(.caption2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .task(id: message.mediaPath) { await loadLocalImageIfNeeded() }
    }

    /// 非空的识图描述；空白字符串按「未识别」处理，避免撑出空行。
    private var imageDescription: String? {
        guard let value = message.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private var finderFeed: WeChatAppmsg.FinderFeed? {
        guard let appmsg = WeChatAppmsg.parse(eventJSON: message.rawJSON),
              appmsg.type == 51 || appmsg.type == 53 else { return nil }
        return appmsg.finderFeed
    }

    @ViewBuilder
    private func finderFeedContent(feed: WeChatAppmsg.FinderFeed) -> some View {
        let coverSize = finderFeedCoverSize(feed)
        VStack(alignment: .leading, spacing: 7) {
            if let imageURL = feed.imageURL {
                Button {
                    openImagePreview(imageURL, title: L("视频号封面"))
                } label: {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            mediaPlaceholder(symbol: "play.rectangle", title: "视频号封面不可用", width: coverSize.width)
                        } else {
                            ZStack {
                                Color.primary.opacity(0.08)
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(L("点击放大查看"))
                .accessibilityLabel(L("点击放大查看"))
                .frame(width: coverSize.width, height: coverSize.height)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(feed.isLive ? L("视频号直播") : L("视频号"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if !feed.nickname.isEmpty {
                Text(feed.nickname)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            if !feed.description.isEmpty {
                Text(feed.description)
                    .font(.caption)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if feed.nickname.isEmpty && feed.description.isEmpty {
                Text(message.text.isEmpty ? L("视频号分享") : message.text)
                    .font(.callout)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    private func finderFeedCoverSize(_ feed: WeChatAppmsg.FinderFeed) -> CGSize {
        let maxWidth: CGFloat = 220
        let maxHeight: CGFloat = 280
        let ratio = CGFloat(feed.imageAspectRatio ?? (16.0 / 9.0))
        let width = min(maxWidth, maxHeight * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    @ViewBuilder
    private var imageContentBody: some View {
        if let localImage {
            Button {
                guard let path = message.mediaPath, !path.isEmpty else { return }
                let url = URL(fileURLWithPath: path)
                openImagePreview(
                    url,
                    title: url.lastPathComponent,
                    loadOriginal: loadHighResolutionImage
                )
            } label: {
                Image(nsImage: localImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L("点击放大查看"))
            .accessibilityLabel(L("点击放大查看"))
        } else if let remoteImageURL {
            AsyncImage(url: remoteImageURL) { phase in
                switch phase {
                case .success(let image):
                    Button {
                    openImagePreview(
                        remoteImageURL,
                        title: remoteImageURL.lastPathComponent,
                        loadOriginal: loadHighResolutionImage
                    )
                    } label: {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 220)
                    }
                    .buttonStyle(.plain)
                    .help(L("点击放大查看"))
                    .accessibilityLabel(L("点击放大查看"))
                    .frame(maxWidth: 240, maxHeight: 220)
                    .contentShape(Rectangle())
                case .failure:
                    mediaPlaceholder(symbol: "photo.badge.exclamationmark", title: "图片加载失败", width: 168)
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 168, height: 108)
                @unknown default:
                    mediaPlaceholder(symbol: "photo", title: "图片", width: 168)
                }
            }
            .frame(maxWidth: 240, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(spacing: 6) {
                mediaPlaceholder(
                    symbol: imageFetchFailed ? "photo.badge.exclamationmark" : "photo",
                    title: imageFetchFailed ? "图片获取失败" : "图片",
                    width: 168
                )
                if let onRetryImage {
                    Button {
                        onRetryImage(message)
                    } label: {
                        Label(L("重新获取图片"), systemImage: "arrow.clockwise")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help(L("从微信重新下载这张图片"))
                }
            }
        }
    }

    private var voiceContent: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .medium))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(voiceDurationLabel)
                        .font(.callout)
                    if message.voiceTranscriptState == .pending {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                if voiceTranscriptVisible, let transcript = voiceTranscript {
                    Text(transcript)
                        .font(.caption)
                        .lineSpacing(2)
                        .lineLimit(5)
                        .opacity(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 240, alignment: .leading)
                } else if voiceTranscriptVisible, message.voiceTranscriptState == .pending {
                    Text(L("转写中…"))
                        .font(.system(size: 10))
                        .opacity(0.7)
                }
                if message.voiceTranscriptState == .failed {
                    if let onRetryVoice {
                        Button {
                            onRetryVoice(message)
                        } label: {
                            Label(L("转写失败 · 重试"), systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .opacity(0.85)
                        .help(L("重新获取并转写这条语音"))
                    } else {
                        Text(L("转写失败"))
                            .font(.system(size: 10))
                            .opacity(0.7)
                    }
                }
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    /// 语音时长标签：「语音 5s」；未知时长时只显示「语音」。
    private var voiceDurationLabel: String {
        guard let durationMs = message.voiceDurationMs, durationMs > 0 else {
            return L("语音")
        }
        let seconds = max(1, Int((Double(durationMs) / 1000).rounded()))
        return "\(L("语音")) \(seconds)s"
    }

    /// 非空转写文本；空白按「没有转写」处理。
    private var voiceTranscript: String? {
        ChatEngine.normalizedVoiceTranscript(message)
    }

    private var fileContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .opacity(0.9)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.callout)
                    .lineLimit(1)
                Text(L("文件"))
                    .font(.system(size: 9))
                    .opacity(0.7)
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var videoContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.14))
                .frame(width: 168, height: 100)
            VStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                Text(L("视频"))
                    .font(.caption2)
            }
        }
    }

    private var linkContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
            Text(message.text.isEmpty ? (message.mediaURL ?? L("链接")) : message.text)
                .font(.callout)
                .lineLimit(2)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func mediaPlaceholder(symbol: String, title: String, width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                Text(L(title))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: width, height: 100)
    }

    @MainActor
    private func saveImage(atPath path: String) {
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            // 写目标副本，不能把缓存源文件交给 replaceItemAt，否则可能移动掉缓存图片。
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @MainActor
    private func saveImage(from url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = message.kind == .image ? "图片.jpg" : "视频号封面.jpg"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.mimeType?.hasPrefix("image/") == true else {
                    throw NSError(
                        domain: "WeChatAI.ImageDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: L("无法下载图片")]
                    )
                }
                try data.write(to: destination, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private var fileName: String {
        if let path = message.mediaPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return message.text.isEmpty ? "文件" : message.text
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Text(UIFormat.time.string(from: message.timestamp))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if message.isOutgoing {
                statusView
            }
        }
        .padding(.horizontal, 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .generating:
            HStack(spacing: 3) {
                TypingIndicator()
                Text(L("生成中"))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
            }
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.success)
        case .failed:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(L("发送失败"))
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.danger)
        case .received:
            EmptyView()
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        parts.append(message.isOutgoing ? L("我发送") : Lf("%@ 发送", message.displaySender))
        switch message.kind {
        case .text: parts.append(message.text)
        case .image:
            parts.append(L("图片"))
            if let description = imageDescription {
                parts.append(Lf("识图描述 %@", description))
            }
        case .voice:
            parts.append(voiceDurationLabel)
            if let transcript = voiceTranscript {
                parts.append(transcript)
            } else if message.voiceTranscriptState == .failed {
                parts.append(L("转写失败"))
            }
        case .emoji: parts.append(Lf("表情 %@", message.text))
        case .file: parts.append(Lf("文件 %@", fileName))
        case .video: parts.append(L("视频"))
        case .link: parts.append(Lf("链接 %@", message.text))
        case .system: parts.append(message.text)
        }
        if message.isOutgoing {
            switch message.status {
            case .generating: parts.append(L("生成中"))
            case .pending: parts.append(L("待发送"))
            case .sent: parts.append(L("已发送"))
            case .failed: parts.append(L("发送失败"))
            case .received: break
            }
        }
        parts.append(UIFormat.stamp(message.timestamp))
        return parts.joined(separator: L10n.listSeparator)
    }

    private func accessibilityDescription(call: WeChatVoIPCall) -> String {
        let sender = message.isOutgoing ? L("我发送") : Lf("%@ 发送", message.displaySender)
        return [sender, call.summary, UIFormat.stamp(message.timestamp)]
            .joined(separator: L10n.listSeparator)
    }
}

/// Centered system notice (connection errors, AI failures, service hints).
struct SystemNoticeRow: View, Equatable {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(message.text.isEmpty ? L("系统消息") : message.text)
                .font(.caption)
                .multilineTextAlignment(.center)
            Text(UIFormat.time.string(from: message.timestamp))
                .font(.system(size: 9))
                .opacity(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Three-dot "AI is typing" indicator. Static under Reduce Motion.
struct TypingIndicator: View {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tint)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(reduceMotion ? 0.55 : (tick == index ? 1 : 0.3))
                        .scaleEffect(reduceMotion ? 1 : (tick == index ? 1.25 : 0.9))
                }
            }
        }
        .frame(height: 12)
        .accessibilityLabel(L("正在生成回复"))
    }
}

/// Day / time separator between message bubbles.
struct DateSeparator: View, Equatable {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(UIFormat.stamp(date))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityLabel(Lf("日期 %@", UIFormat.stamp(date)))
    }
}
