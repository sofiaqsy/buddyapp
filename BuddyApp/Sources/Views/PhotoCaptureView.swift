import SwiftUI
import PhotosUI
import AVFoundation

/// "Agregar foto" en toda la app (Keyla, 26 Nov 2026): la cámara se abre sola y,
/// en la misma pantalla, un botón para elegir de la galería. Devuelve JPEG
/// (máx. 1600 px, 0.8), como el resto de las subidas.
struct PhotoCaptureView: View {
    var maxCount: Int = 1
    let onPick: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()
    @State private var galleryItems: [PhotosPickerItem] = []
    @State private var loadingGallery = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.state == .running {
                BuddyCameraPreview(session: camera.session).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
                    Text(camera.state == .denied
                         ? "Buddy no tiene permiso para usar la cámara. Actívalo en Ajustes, o elige una foto de tu galería."
                         : camera.state == .unavailable ? "La cámara no está disponible. Elige una foto de tu galería." : "Abriendo la cámara…")
                        .font(BT.footnote).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    if camera.state == .denied {
                        Button("Abrir Ajustes") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(BT.footnoteBold).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 40).background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel("Cerrar")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                HStack {
                    // Galería en la misma pantalla.
                    PhotosPicker(selection: $galleryItems, maxSelectionCount: max(1, maxCount), matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .semibold))
                            Text("Galería").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white).frame(width: 72, height: 60)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityLabel("Elegir de la galería")
                    Spacer()
                    Button { camera.capture() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                            Circle().fill(.white).frame(width: 64, height: 64)
                        }
                    }
                    .disabled(camera.state != .running || camera.capturing)
                    .opacity(camera.state == .running ? 1 : 0.4)
                    .accessibilityLabel("Tomar foto")
                    Spacer()
                    Button { camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 72, height: 60)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(camera.state != .running)
                    .opacity(camera.state == .running ? 1 : 0.4)
                    .accessibilityLabel("Cambiar de cámara")
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }

            if loadingGallery || camera.capturing {
                ProgressView().tint(.white).controlSize(.large)
            }
        }
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.captured) { _, data in
            guard let data else { return }
            onPick([data]); dismiss()
        }
        .onChange(of: galleryItems) { _, items in
            guard !items.isEmpty else { return }
            loadingGallery = true
            Task {
                var out: [Data] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let j = PhotoCaptureView.jpeg(d) { out.append(j) }
                }
                loadingGallery = false
                if !out.isEmpty { onPick(out); dismiss() }
            }
        }
    }

    /// JPEG de máx. 1600 px a 0.8.
    static func jpeg(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        return jpeg(img)
    }
    static func jpeg(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 1600
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let r = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return r.jpegData(compressionQuality: 0.8)
    }
}

extension View {
    /// Presenta la cámara con la galería en la misma pantalla.
    func photoCapture(isPresented: Binding<Bool>, maxCount: Int = 1, onPick: @escaping ([Data]) -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) { PhotoCaptureView(maxCount: maxCount, onPick: onPick) }
    }
}

@MainActor
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum State { case starting, running, denied, unavailable }
    @Published var state: State = .starting
    @Published var capturing = false
    @Published var captured: Data? = nil
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var position: AVCaptureDevice.Position = .back
    private let queue = DispatchQueue(label: "buddy.camera")

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default: state = .denied; return
        }
        guard configure() else { state = .unavailable; return }
        let s = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { s.startRunning(); c.resume() }
        }
        state = .running
    }

    func stop() {
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
        }
        return true
    }

    func flip() {
        position = position == .back ? .front : .back
        if !configure() { position = position == .back ? .front : .back; _ = configure() }
    }

    func capture() {
        capturing = true
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.capturing = false
            if let data, let img = UIImage(data: data), let j = PhotoCaptureView.jpeg(img) { self.captured = j }
        }
    }
}

private struct BuddyCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView(); v.layer2.session = session; v.layer2.videoGravity = .resizeAspectFill; return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layer2: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
