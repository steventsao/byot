import ImageIO
import SwiftUI
import UIKit

struct OpenCodeInlineImageItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let source: OpenCodeInlineImage
}

/// Decodes transcript images off the main thread, downsampled to the size
/// they are shown at, and keeps recent results so scrolling back is instant.
@MainActor
final class OpenCodeInlineImageLoader {
    static let shared = OpenCodeInlineImageLoader()
    static let thumbnailPixels = 720
    static let fullScreenPixels = 3_072

    private let images = NSCache<NSString, UIImage>()
    private let serverData = NSCache<NSString, NSData>()

    init() {
        images.totalCostLimit = 64 * 1_024 * 1_024
        serverData.totalCostLimit = 16 * 1_024 * 1_024
    }

    func image(for item: OpenCodeInlineImageItem, maxPixelSize: Int, files: OpenCodeRemoteFileStore?) async throws -> UIImage {
        let key = "\(cacheScope(item, files: files))|\(maxPixelSize)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let data = try await data(for: item, files: files)
        try Task.checkCancellation()
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixelSize: maxPixelSize)
        }.value
        guard let decoded else { throw OpenCodeInlineImageError.undecodable }
        let image = UIImage(cgImage: decoded)
        images.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    private func data(for item: OpenCodeInlineImageItem, files: OpenCodeRemoteFileStore?) async throws -> Data {
        switch item.source {
        case .data(let data):
            return data
        case .serverFile(let path):
            guard let files else { throw OpenCodeInlineImageError.undecodable }
            let key = cacheScope(item, files: files) as NSString
            if let cached = serverData.object(forKey: key) { return cached as Data }
            let data = try await files.data(path: path)
            serverData.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        }
    }

    private func cacheScope(_ item: OpenCodeInlineImageItem, files: OpenCodeRemoteFileStore?) -> String {
        switch item.source {
        case .data: item.id
        case .serverFile(let path): "\(files?.scope.serverID.uuidString ?? "")|\(files?.scope.directory ?? "")|\(path)"
        }
    }

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

enum OpenCodeInlineImageError: LocalizedError {
    case undecodable

    var errorDescription: String? { "This image couldn’t be displayed." }
}

/// Full-screen, zoomable viewer for a message's images, paged when there
/// are several. Dark regardless of appearance, like Photos.
struct OpenCodeImageViewer: View {
    let items: [OpenCodeInlineImageItem]
    let files: OpenCodeRemoteFileStore?
    @State private var index: Int
    @State private var loaded: [String: UIImage] = [:]
    @State private var isChromeHidden = false
    @Environment(\.dismiss) private var dismiss

    init(items: [OpenCodeInlineImageItem], initialIndex: Int, files: OpenCodeRemoteFileStore?) {
        self.items = items
        self.files = files
        _index = State(initialValue: min(max(initialIndex, 0), max(items.count - 1, 0)))
    }

    private var current: OpenCodeInlineImageItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    OpenCodeImageViewerPage(item: item, files: files, onLoad: { loaded[item.id] = $0 }) {
                        isChromeHidden.toggle()
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 && !isChromeHidden ? .always : .never))
            .background(Color.black)
            // Centre on the whole screen; the bars float over the image.
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black.opacity(0.7), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar(isChromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("image-viewer-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let current, let image = loaded[current.id] {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview(current.name, image: Image(uiImage: image))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(isChromeHidden)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var title: String {
        guard let current else { return "Image" }
        return items.count > 1 ? "\(index + 1) of \(items.count)" : current.name
    }
}

private struct OpenCodeImageViewerPage: View {
    let item: OpenCodeInlineImageItem
    let files: OpenCodeRemoteFileStore?
    let onLoad: (UIImage) -> Void
    let onSingleTap: () -> Void
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var zoom = OpenCodeZoomController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image {
                OpenCodeZoomableImage(image: image, reduceMotion: reduceMotion, controller: zoom, onSingleTap: onSingleTap)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityZoomAction { action in
                        zoom.zoom(in: action.direction == .zoomIn)
                    }
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t load image", systemImage: "photo.badge.exclamationmark",
                                       description: Text(errorMessage))
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            do {
                let loaded = try await OpenCodeInlineImageLoader.shared.image(
                    for: item, maxPixelSize: OpenCodeInlineImageLoader.fullScreenPixels, files: files)
                image = loaded
                onLoad(loaded)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Lets SwiftUI accessibility actions drive the UIKit zoom.
@MainActor
final class OpenCodeZoomController {
    weak var view: OpenCodeZoomingScrollView?

    func zoom(in zoomIn: Bool) {
        guard let view else { return }
        let step: CGFloat = zoomIn ? 1.5 : 1 / 1.5
        let scale = min(max(view.zoomScale * step, view.minimumZoomScale), view.maximumZoomScale)
        view.setZoomScale(scale, animated: !view.reduceMotion)
    }
}

private struct OpenCodeZoomableImage: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    let controller: OpenCodeZoomController
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> OpenCodeZoomingScrollView {
        let view = OpenCodeZoomingScrollView(image: image)
        controller.view = view
        return view
    }

    func updateUIView(_ view: OpenCodeZoomingScrollView, context: Context) {
        view.reduceMotion = reduceMotion
        view.onSingleTap = onSingleTap
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setZoomScale(view.minimumZoomScale, animated: false)
            view.setNeedsLayout()
        }
    }
}

/// Pinch and double-tap zoom, with the image fitted and centred at rest.
final class OpenCodeZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var reduceMotion = false
    var onSingleTap: (() -> Void)?
    private var fittedBounds: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        minimumZoomScale = 1
        maximumZoomScale = 4
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let size = imageView.image?.size,
              size.width > 0, size.height > 0 else { return }
        // Refit at rest, for example after rotation; never while zoomed.
        if zoomScale == minimumZoomScale, fittedBounds != bounds.size {
            fittedBounds = bounds.size
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        center()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    private func center() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + x, y: contentSize.height / 2 + y)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: !reduceMotion)
            return
        }
        let scale = min(maximumZoomScale, 2.5)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size),
             animated: !reduceMotion)
    }

    @objc private func singleTapped() { onSingleTap?() }
}
