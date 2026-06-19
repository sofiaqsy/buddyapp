import SwiftUI
import AVFoundation

// MARK: – QR Scanner View

struct QRScannerView: View {
    var onDismiss: () -> Void
    var onUnlocked: ((String) -> Void)? = nil   // called with stickerId on success

    @State private var scanState: ScanState = .scanning
    @State private var isProcessing = false

    enum ScanState {
        case scanning
        case success(APIStickerCatalog, Bool) // sticker, alreadyUnlocked
        case error(String)
    }

    var body: some View {
        ZStack {
            // Camera
            CameraPreview { code in
                guard !isProcessing else { return }
                handleScan(code: code)
            }
            .ignoresSafeArea()

            // Dim overlay with cutout window centrado geometricamente
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .frame(width: 250, height: 250)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

            // Top bar — encima del dim
            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text("Escanear sticker")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                Spacer()
                Text("Apunta al código QR del sticker")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 56)
            }
            .ignoresSafeArea()

            // Viewfinder border centrado
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.85), lineWidth: 2.5)
                .frame(width: 250, height: 250)
                .overlay { ViewfinderCorners() }

            // Result overlay
            switch scanState {
            case .success(let sticker, let already):
                StickerScanResultView(sticker: sticker, alreadyUnlocked: already, onDismiss: onDismiss)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            case .error(let msg):
                ScanErrorBanner(message: msg) {
                    withAnimation { scanState = .scanning }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case .scanning:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isProcessing)
    }

    private func handleScan(code: String) {
        // Expects: buddyapp://sticker/{id}
        guard code.hasPrefix("buddyapp://sticker/") else {
            withAnimation { scanState = .error("QR no válido para buddy") }
            return
        }
        let stickerId = String(code.dropFirst("buddyapp://sticker/".count))
        guard !stickerId.isEmpty else { return }

        isProcessing = true
        Haptic.success()

        Task {
            do {
                let result = try await APIClient.shared.unlockStickerByQR(stickerId: stickerId)
                await MainActor.run {
                    withAnimation { scanState = .success(result.sticker, result.alreadyUnlocked) }
                    onUnlocked?(result.sticker.id)
                }
            } catch {
                await MainActor.run {
                    withAnimation { scanState = .error("No se pudo obtener el sticker") }
                    isProcessing = false
                }
            }
        }
    }
}

// MARK: – Camera Preview

struct CameraPreview: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> CameraView {
        let view = CameraView()
        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return view }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.previewLayer = preview
        view.layer.addSublayer(preview)
        context.coordinator.preview = preview

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: CameraView, context: Context) {
        // frame update handled in layoutSubviews
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    // Custom UIView that keeps the preview layer filling its bounds
    class CameraView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        var session: AVCaptureSession?
        var preview: AVCaptureVideoPreviewLayer?
        private var lastCode = ""

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let code = obj.stringValue, code != lastCode else { return }
            lastCode = code
            onCode(code)
        }
    }
}

// MARK: – Viewfinder Corners

struct ViewfinderCorners: View {
    var body: some View {
        ZStack {
            ForEach(0..<4) { i in
                CornerMark()
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
    }
}

struct CornerMark: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: -120, y: -80))
            p.addLine(to: CGPoint(x: -120, y: -120))
            p.addLine(to: CGPoint(x: -80, y: -120))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .frame(width: 240, height: 240)
    }
}

// MARK: – Scan Result

struct StickerScanResultView: View {
    let sticker: APIStickerCatalog
    let alreadyUnlocked: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 20) {
                // Sticker image
                if let urlStr = sticker.imageUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.sandLight }
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                } else {
                    Circle()
                        .fill(Color.sandLight)
                        .frame(width: 120, height: 120)
                }

                if alreadyUnlocked {
                    Text("Ya tienes este sticker")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(sticker.name)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("¡Sticker obtenido!")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text(sticker.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.sand)
                }

                Button(action: onDismiss) {
                    Text("Genial")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.teal)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
            .padding(32)
        }
    }
}

// MARK: – Error Banner

struct ScanErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onDismiss) {
                    Text("OK")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.bottom, 50)
        }
    }
}
