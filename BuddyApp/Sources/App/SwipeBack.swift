import UIKit

// Deslizar a la derecha para volver, en TODA la app (Keyla, 21 Nov 2026: en el
// mapa de un lugar no se podía volver deslizando). iOS apaga este gesto en las
// pantallas que esconden la barra de navegación (el mapa, Comunidad, perfiles…);
// aquí se vuelve a encender para todas. Solo actúa si hay a dónde volver.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }

    /// Junto con el mapa o una lista que se desplaza, gana el gesto de volver
    /// cuando empieza en el borde izquierdo.
    public func gestureRecognizer(_ g: UIGestureRecognizer,
                                  shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g == interactivePopGestureRecognizer
    }
}
