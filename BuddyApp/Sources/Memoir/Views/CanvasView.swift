import SwiftUI

struct CanvasView: View {
    @ObservedObject var vm: CanvasViewModel
    @Binding var canvasSize: CGSize

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background: strip image + white veil, or solid color
                Group {
                    if let bg = vm.backgroundImage {
                        Image(uiImage: bg)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                        Color.white.opacity(0.55)
                            .ignoresSafeArea()
                    } else {
                        vm.canvasBackground
                            .ignoresSafeArea()
                    }
                }
                .onTapGesture { vm.selectedItemId = nil }

                // sortedItems is a vm computed var (avoids sort inside body).
                // .equatable() skips body entirely when item data + selection
                // haven't changed — critical for snap-guide / other-item taps.
                ForEach(vm.sortedItems) { item in
                    CanvasItemView(
                        item:       item,
                        isSelected: vm.selectedItemId == item.id,
                        vm:         vm
                    )
                    .equatable()
                }

                // Smart guide lines — only visible while dragging near a centre axis
                snapGuideLines(in: geo.size)
            }
            .clipped(antialiased: false)
            .onAppear {
                canvasSize    = geo.size
                vm.canvasSize = geo.size
            }
            .onChange(of: geo.size) { _, s in
                canvasSize    = s
                vm.canvasSize = s
            }
        }
    }

    @ViewBuilder
    private func snapGuideLines(in size: CGSize) -> some View {
        // Vertical centre ──────────────────────────────────────────────────────
        Rectangle()
            .fill(Color.accent.opacity(vm.snapGuides.contains(.verticalCenter) ? 0.55 : 0))
            .frame(width: 1, height: size.height)
            .position(x: size.width / 2, y: size.height / 2)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.1), value: vm.snapGuides)

        // Horizontal centre ────────────────────────────────────────────────────
        Rectangle()
            .fill(Color.accent.opacity(vm.snapGuides.contains(.horizontalCenter) ? 0.55 : 0))
            .frame(width: size.width, height: 1)
            .position(x: size.width / 2, y: size.height / 2)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.1), value: vm.snapGuides)
    }
}
