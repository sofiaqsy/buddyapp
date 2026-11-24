import SwiftUI
import UIKit

/// Foto con zoom, la misma en todos los visores (Keyla, 21 Nov 2026: "los
/// usuarios intentan hacer zoom"): pellizcar para acercar (hasta 4x), doble
/// toque acerca o vuelve, y con zoom se arrastra para mirar. Sin zoom, deslizar
/// de lado lo maneja el carrusel que la contiene (como la app Fotos).
/// Un toque simple avisa dónde fue, para "izquierda atrás / derecha adelante".
struct ZoomablePhoto: UIViewRepresentable {
    let urlString: String?
    var onZoomChange: (Bool) -> Void = { _ in }
    /// x del toque como fracción del ancho (0 = borde izquierdo, 1 = derecho).
    var onTap: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = true
        image.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            image.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            image.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            image.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            image.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = image

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
        ])
        context.coordinator.spinner = spinner

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)

        scroll.isAccessibilityElement = true
        scroll.accessibilityLabel = "Foto"
        scroll.accessibilityHint = "Pellizca o toca dos veces para acercar"
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(urlString)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomablePhoto
        weak var imageView: UIImageView?
        weak var spinner: UIActivityIndicatorView?
        private var loadedURL: String?
        private var zoomed = false

        init(_ parent: ZoomablePhoto) { self.parent = parent }

        func load(_ s: String?) {
            guard s != loadedURL else { return }
            loadedURL = s
            imageView?.image = nil
            guard let s, let url = URL(string: s) else { spinner?.stopAnimating(); return }
            if let hit = ImageCache.shared.get(url) { imageView?.image = hit; spinner?.stopAnimating(); return }
            spinner?.startAnimating()
            Task { @MainActor [weak self] in
                let img = await ImageCache.shared.load(url)
                guard let self, self.loadedURL == s else { return }
                self.imageView?.image = img
                self.spinner?.stopAnimating()
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let now = scrollView.zoomScale > 1.01
            if now != zoomed { zoomed = now; parent.onZoomChange(now) }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let scale: CGFloat = 2.5
                let w = scroll.bounds.width / scale, h = scroll.bounds.height / scale
                scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @objc func singleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view, v.bounds.width > 0, !zoomed else { return }
            parent.onTap(g.location(in: v).x / v.bounds.width)
        }
    }
}
