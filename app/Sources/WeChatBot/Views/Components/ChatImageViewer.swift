import ImageIO
import SwiftUI

struct ChatImagePreviewSelection: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let loadOriginal: (@MainActor () async throws -> URL)?
}

/// Full resolution image preview for chat photos and Finder covers.
struct ChatImageViewer: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL
    let title: String
    let loadOriginal: (@MainActor () async throws -> URL)?

    @State private var decodedImage: DecodedChatImage?
    @State private var loadFailed = false
    @State private var isLoadingOriginal = false
    @State private var originalLoadedURL: URL?
    @State private var originalLoadError: String?
    @State private var zoom: CGFloat = 1
    @State private var actualSizeZoom: CGFloat = 1
    @State private var magnificationStart: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panAtDragStart = CGSize.zero

    /// Keep a useful zoom range while always allowing a true 1:1 pixel view,
    /// even when the source image is small or unusually high resolution.
    private var minimumZoom: CGFloat { min(0.01, actualSizeZoom) }
    private var maximumZoom: CGFloat { max(16, actualSizeZoom) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(.white.opacity(0.12))
            imageStage
        }
        .frame(
            minWidth: 680, idealWidth: 920, maxWidth: 1400,
            minHeight: 500, idealHeight: 720, maxHeight: 1100
        )
        .background(.black)
        .task(id: url) { await loadImage() }
        .onExitCommand { dismiss() }
        .alert(L("高清原图获取失败"), isPresented: Binding(
            get: { originalLoadError != nil },
            set: { if !$0 { originalLoadError = nil } }
        )) {
            Button(L("确定"), role: .cancel) { originalLoadError = nil }
        } message: {
            Text(originalLoadError ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("图片预览"))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let decodedImage {
                    Text(Lf(
                        "%d × %d 像素 · %@",
                        decodedImage.image.width,
                        decodedImage.image.height,
                        ByteCountFormatter.string(fromByteCount: decodedImage.byteCount, countStyle: .file)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 8)

            Button {
                updateZoom(zoom / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(L("缩小"))
            .accessibilityLabel(L("缩小"))
            .disabled(zoom <= minimumZoom + 0.0001)

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44)
                .accessibilityLabel(Lf("缩放 %@", "\(Int((zoom * 100).rounded()))%"))

            Button {
                updateZoom(zoom * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(L("放大"))
            .accessibilityLabel(L("放大"))
            .disabled(zoom >= maximumZoom - 0.0001)

            if loadOriginal != nil && originalLoadedURL == nil {
                Button {
                    Task { await fetchOriginalImage() }
                } label: {
                    Label(
                        isLoadingOriginal ? L("正在获取原图…") : L("重试获取原图"),
                        systemImage: isLoadingOriginal ? "arrow.down.circle.dotted" : "arrow.clockwise"
                    )
                }
                .help(L("重新获取高清原图"))
                .disabled(isLoadingOriginal)
            }

            Button(L("原始大小")) {
                updateZoom(actualSizeZoom)
            }
            .help(L("原始大小"))

            Button {
                updateZoom(1)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help(L("适合窗口"))
            .accessibilityLabel(L("适合窗口"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .help(L("关闭图片预览"))
            .accessibilityLabel(L("关闭图片预览"))
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black)
    }

    private var imageStage: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let decodedImage {
                    imageCanvas(decodedImage.image, viewport: proxy.size)
                } else if loadFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 30, weight: .light))
                        Text(L("图片加载失败"))
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                } else {
                    ProgressView(L("正在加载图片…"))
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { updateActualSizeZoom(in: proxy.size) }
            .onChange(of: proxy.size) { _, newSize in
                updateActualSizeZoom(in: newSize)
            }
            .onChange(of: decodedImage?.image.width) { _, _ in
                updateActualSizeZoom(in: proxy.size)
            }
            .onChange(of: decodedImage?.image.height) { _, _ in
                updateActualSizeZoom(in: proxy.size)
            }
        }
        .overlay(alignment: .bottom) {
            Text(L("拖动移动图片；捏合缩放，双击切换原始大小"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }

    private func imageCanvas(_ image: CGImage, viewport: CGSize) -> some View {
        let available = CGSize(
            width: max(1, viewport.width - 40),
            height: max(1, viewport.height - 40)
        )
        let fitScale = min(
            available.width / CGFloat(image.width),
            available.height / CGFloat(image.height)
        )
        let fittedSize = CGSize(
            width: CGFloat(image.width) * fitScale,
            height: CGFloat(image.height) * fitScale
        )

        return Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: fittedSize.width, height: fittedSize.height)
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = min(maximumZoom, max(minimumZoom, magnificationStart * value))
                        if zoom <= 1 { pan = .zero; panAtDragStart = .zero }
                    }
                    .onEnded { _ in magnificationStart = zoom }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        let proposed = CGSize(
                            width: panAtDragStart.width + value.translation.width,
                            height: panAtDragStart.height + value.translation.height
                        )
                        pan = clampedPan(proposed, fittedSize: fittedSize, viewport: viewport)
                    }
                    .onEnded { _ in panAtDragStart = pan }
            )
            .onTapGesture(count: 2) {
                updateZoom(abs(zoom - 1) > 0.02 ? 1 : actualSizeZoom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(L("图片"))
    }

    private func clampedPan(_ proposed: CGSize, fittedSize: CGSize, viewport: CGSize) -> CGSize {
        let horizontalLimit = max(0, (fittedSize.width * zoom - viewport.width) / 2)
        let verticalLimit = max(0, (fittedSize.height * zoom - viewport.height) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, proposed.width)),
            height: min(verticalLimit, max(-verticalLimit, proposed.height))
        )
    }

    private func updateZoom(_ value: CGFloat) {
        zoom = min(maximumZoom, max(minimumZoom, value))
        magnificationStart = zoom
        if zoom <= 1 {
            pan = .zero
            panAtDragStart = .zero
        }
    }

    private func updateActualSizeZoom(in viewport: CGSize) {
        guard let image = decodedImage?.image,
              viewport.width > 0, viewport.height > 0 else { return }
        let availableWidth = max(1, viewport.width - 40)
        let availableHeight = max(1, viewport.height - 40)
        let fitScale = min(
            availableWidth / CGFloat(image.width),
            availableHeight / CGFloat(image.height)
        )
        guard fitScale > 0 else { return }
        actualSizeZoom = 1 / fitScale
    }

    @MainActor
    private func loadImage() async {
        loadFailed = false
        decodedImage = nil
        originalLoadedURL = nil
        originalLoadError = nil
        do {
            let result = try await decodeImage(from: url)
            guard !Task.isCancelled else { return }
            decodedImage = result
            guard let loadOriginal else { return }
            await fetchOriginalImage(using: loadOriginal)
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    @MainActor
    private func fetchOriginalImage() async {
        guard let loadOriginal else { return }
        await fetchOriginalImage(using: loadOriginal)
    }

    @MainActor
    private func fetchOriginalImage(using loadOriginal: @MainActor () async throws -> URL) async {
        guard !isLoadingOriginal else { return }
        isLoadingOriginal = true
        originalLoadError = nil
        defer { isLoadingOriginal = false }
        do {
            let originalURL = try await loadOriginal()
            let result = try await decodeImage(from: originalURL)
            guard !Task.isCancelled else { return }
            decodedImage = result
            originalLoadedURL = originalURL
            loadFailed = false
            updateZoom(1)
        } catch {
            guard !Task.isCancelled else { return }
            originalLoadError = error.localizedDescription
        }
    }

    @MainActor
    private func decodeImage(from sourceURL: URL) async throws -> DecodedChatImage {
        if sourceURL.isFileURL {
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                return try Self.decodeFullResolution(data, byteCount: Int64(data.count))
            }.value
        }
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true else {
            throw ImageViewerError.invalidResponse
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.decodeFullResolution(data, byteCount: Int64(data.count))
        }.value
    }

    private nonisolated static func decodeFullResolution(
        _ data: Data,
        byteCount: Int64
    ) throws -> DecodedChatImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageViewerError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxPixelSize = max(sourceWidth, max(sourceHeight, 1))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageViewerError.invalidImage
        }
        return DecodedChatImage(image: image, byteCount: byteCount)
    }
}

private struct DecodedChatImage: @unchecked Sendable {
    let image: CGImage
    let byteCount: Int64
}

private enum ImageViewerError: Error {
    case invalidImage
    case invalidResponse
}
