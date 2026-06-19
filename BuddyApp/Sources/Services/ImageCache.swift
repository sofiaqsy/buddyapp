import SwiftUI
import Combine

// MARK: – Image Cache (memory + disk)

final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("buddy_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        memory.totalCostLimit = 80 * 1024 * 1024  // 80 MB
        memory.countLimit = 120
    }

    func get(_ url: URL) -> UIImage? {
        let key = cacheKey(url)
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = diskURL.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString, cost: data.count)
            return img
        }
        return nil
    }

    func set(_ image: UIImage, for url: URL) {
        let key = cacheKey(url)
        let data = image.jpegData(compressionQuality: 0.85) ?? Data()
        memory.setObject(image, forKey: key as NSString, cost: data.count)
        let file = diskURL.appendingPathComponent(key)
        try? data.write(to: file, options: .atomic)
    }

    func load(_ url: URL) async -> UIImage? {
        if let cached = get(url) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        set(image, for: url)
        return image
    }

    private func cacheKey(_ url: URL) -> String {
        url.absoluteString
            .data(using: .utf8)
            .map { $0.base64EncodedString() }?
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            ?? url.lastPathComponent
    }
}

// MARK: – Shimmer Effect

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let width = geo.size.width * 2.5
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.18),
                            .white.opacity(0.32),
                            .white.opacity(0.18),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width)
                    .offset(x: phase * (geo.size.width + width) - width / 2)
                    .blendMode(.plusLighter)
                }
                .clipped()
            )
            // Usar .animation(value:) en lugar de withAnimation en onAppear
            // para que la animación repeatForever no se filtre a la jerarquía padre
            .animation(
                .linear(duration: 1.4).repeatForever(autoreverses: false),
                value: phase
            )
            .onAppear { phase = 1 }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: – Skeleton placeholder shapes

struct SkeletonBox: View {
    var cornerRadius: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.18))
            .shimmer()
    }
}

// MARK: – CachedImage View

struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage? = nil
    @State private var isLoading = false

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let img = uiImage {
                content(Image(uiImage: img))
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else {
                ZStack {
                    placeholder()
                    // Show shimmer only while actively loading from network
                    if isLoading {
                        Color.black.opacity(0.001) // transparent touch absorber
                            .shimmer()
                    }
                }
            }
        }
        // Sin guard de "ya tengo imagen": si la URL cambia (p. ej. de cover
        // del destino → portada real cargada async), hay que recargar.
        // La imagen anterior queda visible hasta que llega la nueva (sin parpadeo).
        .task(id: url?.absoluteString) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { return }
        // Hit de memoria/disco — disco + decodificación SIEMPRE fuera del main;
        // la asignación de @State, en main.
        if let cached = await Task.detached(priority: .userInitiated, operation: {
            ImageCache.shared.get(url)
        }).value {
            await MainActor.run { uiImage = cached }
            return
        }
        // Network load — show shimmer
        await MainActor.run { isLoading = true }
        let img = await ImageCache.shared.load(url)
        await MainActor.run {
            if let img { uiImage = img }
            isLoading = false
        }
    }
}

// MARK: – Convenience inits

extension CachedImage where Placeholder == Color {
    init(urlString: String?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(
            url: urlString.flatMap { URL(string: $0) },
            content: content,
            placeholder: { Color.gray.opacity(0.15) }
        )
    }
}

extension CachedImage {
    init(urlString: String?, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(
            url: urlString.flatMap { URL(string: $0) },
            content: content,
            placeholder: placeholder
        )
    }
}

// MARK: – Prefetch helper

enum ImagePrefetcher {
    static func prefetch(_ urls: [String]) {
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                for urlStr in urls.prefix(20) {
                    guard let url = URL(string: urlStr) else { continue }
                    group.addTask { _ = await ImageCache.shared.load(url) }
                }
            }
        }
    }
}
