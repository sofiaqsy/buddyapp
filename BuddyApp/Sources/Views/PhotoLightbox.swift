import SwiftUI

/// Una foto, a pantalla completa.
///
/// Tocar una miniatura abría la cuadrícula con TODAS las fotos del lugar, que
/// responde a "quiero ver el resto" y no a "quiero ver ésta". El gesto de tocar
/// una foto concreta solo puede significar lo segundo; ver el resto ya tiene su
/// propia entrada, "Ver todas".
///
/// Fondo negro y sin cromo: la foto es lo único que importa aquí, y cualquier
/// panel encima le quita sitio a lo que el usuario vino a mirar.
struct PhotoLightbox: View {
    let photo: GalleryPhoto

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var scaleAlEmpezar: CGFloat = 1
    @State private var desplazamiento: CGSize = .zero
    @State private var desplazamientoAlEmpezar: CGSize = .zero

    private let zoomMaximo: CGFloat = 4
    /// A partir de cuánto arrastre hacia abajo se cierra. 120pt es un gesto
    /// deliberado: más corto y se cierra sola al intentar mirar de cerca.
    private let umbralCierre: CGFloat = 120

    private var estaAmpliada: Bool { scale > 1.01 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CachedImage(urlString: photo.url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                // Sobre negro, un rectángulo claro daría un fogonazo mientras
                // carga. El progress dice "viene en camino" sin deslumbrar.
                ProgressView().tint(.white)
            }
            .scaleEffect(scale)
            .offset(desplazamiento)
            .gesture(gestoDeZoom)
            .simultaneousGesture(gestoDeArrastre)
            .onTapGesture(count: 2) { alternarZoom() }

            cerrar
        }
        .statusBarHidden()
        // La opacidad sigue al arrastre: al bajar la foto se ve el fondo
        // aclararse, que es lo que anticipa que soltar va a cerrar.
        .opacity(estaAmpliada ? 1 : max(0.35, 1 - abs(desplazamiento.height) / 400))
    }

    // MARK: Cromo

    private var cerrar: some View {
        Button {
            Haptic.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .padding(.leading, Spacing.edge)
        .padding(.top, Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Gestos

    private var gestoDeZoom: some Gesture {
        MagnificationGesture()
            .onChanged { valor in
                scale = min(max(scaleAlEmpezar * valor, 1), zoomMaximo)
            }
            .onEnded { _ in
                scaleAlEmpezar = scale
                // Al volver a 1 se recentra: una foto sin ampliar descolocada
                // se lee como un fallo de maquetado.
                if !estaAmpliada { withAnimation(.easeOut(duration: 0.2)) { recentrar() } }
            }
    }

    /// Arrastrar mueve la foto cuando está ampliada, y la cierra cuando no.
    /// Son el mismo gesto porque en una foto sin ampliar no hay nada que
    /// desplazar, así que no compiten.
    private var gestoDeArrastre: some Gesture {
        DragGesture()
            .onChanged { valor in
                if estaAmpliada {
                    desplazamiento = CGSize(
                        width:  desplazamientoAlEmpezar.width  + valor.translation.width,
                        height: desplazamientoAlEmpezar.height + valor.translation.height)
                } else {
                    // Solo vertical: en horizontal no hay a dónde ir y seguir el
                    // dedo de lado sugeriría que hay otra foto al lado.
                    desplazamiento = CGSize(width: 0, height: valor.translation.height)
                }
            }
            .onEnded { valor in
                if estaAmpliada {
                    desplazamientoAlEmpezar = desplazamiento
                    return
                }
                if valor.translation.height > umbralCierre {
                    Haptic.light()
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { recentrar() }
                }
            }
    }

    private func alternarZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if estaAmpliada {
                scale = 1
                recentrar()
            } else {
                scale = 2.5
            }
            scaleAlEmpezar = scale
        }
    }

    private func recentrar() {
        desplazamiento = .zero
        desplazamientoAlEmpezar = .zero
    }
}
