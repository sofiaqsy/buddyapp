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

    /// Conteo TEMPORAL para validar el dedupe. Cuenta todas las imágenes, no
    /// solo las que logOrigin imprime — ese print está filtrado a memoir-photos
    /// y dejaría fuera los avatares, que son precisamente los que más se
    /// repiten entre tarjetas del feed.
    private static var stats: [String: Int] = [:]
    private static let statsLock = NSLock()
    private static func contar(_ que: String) {
        statsLock.lock(); stats[que, default: 0] += 1; statsLock.unlock()
    }

    static func resumen(_ momento: String) {
        statsLock.lock(); let s = stats; statsLock.unlock()
        guard !s.isEmpty else { return }
        let mem = s["memoria"] ?? 0, disco = s["disco"] ?? 0
        let red = s["red"] ?? 0, vuelo = s["enVuelo"] ?? 0
        print("📊 [ImageCache] ── \(momento): memoria=\(mem) disco=\(disco) red=\(red) deduplicadas=\(vuelo) ──")
        if vuelo > 0 {
            print("📊 [ImageCache]   \(vuelo) descarga(s) evitada(s) por dedupe en vuelo ✅")
        }
    }

    func get(_ url: URL) -> UIImage? {
        let key = cacheKey(url)
        if let img = memory.object(forKey: key as NSString) {
            ImageCache.contar("memoria")
            ImageCache.logOrigin("memoria", url)
            return img
        }
        let file = diskURL.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString, cost: data.count)
            ImageCache.contar("disco")
            ImageCache.logOrigin("disco", url)
            return img
        }
        // Antes acá se imprimía «red ←», y era engañoso: esto es un FALLO de
        // caché, no una descarga. Peor, CachedImage.loadImage llama a get() y
        // después a load(), que vuelve a llamar a get() — así que una sola
        // imagen producía DOS líneas «red ←». Sobre esas dos líneas concluí que
        // la misma foto se descargaba dos veces; era falso: una descarga, dos
        // fallos de caché logueados. Ahora «red ←» se imprime donde de verdad
        // se sale a la red.
        return nil
    }

    /// Solo fotos de memoir: son las únicas con ruta reciclada (page_N.jpg), y
    /// el resto del feed inundaría la consola.
    static func logOrigin(_ origin: String, _ url: URL) {
        guard url.absoluteString.contains("memoir-photos") else { return }
        print("🖼️ [ImageCache] \(origin) ← \(shortLog(url))")
    }

    static func shortLog(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        return c.path.split(separator: "/").suffix(2).joined(separator: "/") + (c.query.map { "?\($0)" } ?? " «sin ?v=»")
    }

    func set(_ image: UIImage, for url: URL) {
        let key = cacheKey(url)
        // Memoria: NSCache es thread-safe, se puede escribir desde cualquier hilo
        let data = image.jpegData(compressionQuality: 0.85) ?? Data()
        memory.setObject(image, forKey: key as NSString, cost: data.count)
        // Disco: JPEG encoding + write nunca en el main thread
        let file = diskURL.appendingPathComponent(key)
        Task(priority: .utility) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Saca UNA imagen de memoria y disco.
    ///
    /// Puntual y no un vaciado completo: cuando se borra una foto se conoce su
    /// URL exacta, así que no hay razón para tirar las del resto del Home y del
    /// perfil y volver a bajarlas. NSCache no se puede recorrer, pero sí se le
    /// puede pedir una clave concreta.
    func remove(_ url: URL) {
        let key = cacheKey(url)
        print("🧹 [ImageCache] remove \(ImageCache.shortLog(url))")
        memory.removeObject(forKey: key as NSString)
        let file = diskURL.appendingPathComponent(key)
        Task(priority: .utility) { try? FileManager.default.removeItem(at: file) }
    }

    /// Descargas en vuelo, para que dos vistas que piden la MISMA url no
    /// descarguen ni decodifiquen dos veces.
    ///
    /// El caso real no es una vista pidiendo dos veces: es el mismo avatar en
    /// varias tarjetas del feed montando a la vez. En el log se veía como
    /// cuatro «disco ←» seguidas del mismo archivo — cuatro lecturas y cuatro
    /// decodificaciones JPEG del mismo dato, porque las cuatro fallaron el
    /// caché de memoria antes de que la primera terminara de llenarlo.
    ///
    /// Mismo patrón que InFlightRegistry, pero con NSLock en vez de @MainActor:
    /// esto se llama desde tareas de fondo y forzar un salto al hilo principal
    /// por cada imagen sería peor que el problema que resuelve.
    private var descargasEnVuelo: [URL: Task<UIImage?, Never>] = [:]
    private let enVueloLock = NSLock()

    func load(_ url: URL) async -> UIImage? {
        if let cached = get(url) { return cached }

        enVueloLock.lock()
        if let existente = descargasEnVuelo[url] {
            enVueloLock.unlock()
            ImageCache.contar("enVuelo")
            ImageCache.logOrigin("♻️ en vuelo", url)
            return await existente.value
        }
        let task = Task<UIImage?, Never> {
            ImageCache.contar("red")
            ImageCache.logOrigin("red", url)
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            self.set(image, for: url)
            return image
        }
        descargasEnVuelo[url] = task
        enVueloLock.unlock()

        let img = await task.value
        enVueloLock.lock()
        descargasEnVuelo[url] = nil
        enVueloLock.unlock()
        return img
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

// MARK: – Skeleton pulse animation

struct SkeletonPulseModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            // 0.62 y 1.25s, antes 0.45 y 0.9s. El pulso viejo bajaba a menos de
            // la mitad de opacidad en menos de un segundo: se leía como un
            // parpadeo de alarma y llamaba más la atención que el contenido que
            // estaba esperando. Una respiración lenta y poco profunda es lo que
            // hacen Wallet y App Store — dice "esto está vivo" sin pedir nada.
            .opacity(pulsing ? 0.62 : 1.0)
            .animation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

extension View {
    func skeletonPulse() -> some View {
        modifier(SkeletonPulseModifier())
    }
}

// MARK: – Skeleton placeholder shapes

struct SkeletonBox: View {
    var cornerRadius: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.groupedBg)
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
            placeholder: { Color.groupedBg.opacity(0.8) }
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
