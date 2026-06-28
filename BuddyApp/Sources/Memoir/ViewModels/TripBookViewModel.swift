import SwiftUI

@MainActor
final class TripBookViewModel: ObservableObject {

    let journeyId: String

    @Published var pages: [CollagePage] = []
    @Published var currentPageIndex: Int = 0
    @Published var isEditing: Bool = false
    @Published var editingVM: CanvasViewModel = CanvasViewModel()
    @Published var isLoadingPage: Bool = false

    private var vmCache: [UUID: CanvasViewModel] = [:]
    private let persistence = MemoirPersistence.shared

    init(journeyId: String) {
        self.journeyId = journeyId
        pages = persistence.load(journeyId: journeyId)
        if pages.isEmpty { pages.append(CollagePage()) }
        assignBackgroundStrips()
    }

    var currentPage: CollagePage { pages[currentPageIndex] }

    // MARK: - Enter / Exit edit

    func enterEdit(at index: Int) {
        currentPageIndex = index
        isEditing = true
        let id = pages[index].id
        if let cached = vmCache[id] { editingVM = cached; return }
        loadPage(at: index)
    }

    func exitEdit(canvasSize: CGSize = .zero) {
        let jId = journeyId
        print("📓 [exitEdit] journeyId=\(jId) pageCount=\(pages.count) canvasSize=\(canvasSize)")
        if canvasSize != .zero { editingVM.canvasSize = canvasSize }
        print("📓 [exitEdit] vm.canvasSize after update=\(editingVM.canvasSize) items=\(editingVM.items.count)")
        vmCache[pages[currentPageIndex].id] = editingVM
        flushCacheToDisk()
        vmCache.removeAll()
        isEditing = false
        for (i, p) in pages.enumerated() {
            print("📓 [exitEdit] page[\(i)] id=\(p.id) items=\(p.itemSnapshots.count) bgFile=\(p.backgroundImageFile ?? "nil") thumbFile=\(p.thumbnailFileName ?? "nil")")
        }
        saveAsync()
    }

    // MARK: - Navigation

    func navigateToNext() {
        guard currentPageIndex < pages.count - 1 else { return }
        switchPage(to: currentPageIndex + 1)
    }

    func navigateToPrevious() {
        guard currentPageIndex > 0 else { return }
        switchPage(to: currentPageIndex - 1)
    }

    private func switchPage(to index: Int) {
        vmCache[pages[currentPageIndex].id] = editingVM
        currentPageIndex = index
        let id = pages[index].id
        if let cached = vmCache[id] { editingVM = cached; return }
        loadPage(at: index)
    }

    private func loadPage(at index: Int) {
        isLoadingPage = true
        let page    = pages[index]
        let pageId  = page.id
        let jId     = journeyId

        Task {
            let (items, bgImage) = await Task.detached(priority: .userInitiated) {
                let items   = MemoirPersistence.shared.buildItems(from: page, journeyId: jId)
                let bgImage = page.backgroundImageFile
                    .flatMap { MemoirPersistence.shared.loadBackground($0, journeyId: jId) }
                return (items, bgImage)
            }.value

            let bg = persistence.backgroundColor(from: page)
            let vm = CanvasViewModel()
            vm.canvasBackground = bg
            vm.backgroundImage  = bgImage
            vm.items = items

            guard pages.indices.contains(index), pages[index].id == pageId else {
                isLoadingPage = false; return
            }
            vmCache[pageId] = vm
            editingVM = vm
            isLoadingPage = false
        }
    }

    // MARK: - Add / Delete pages

    func addPage() {
        if isEditing { vmCache[pages[currentPageIndex].id] = editingVM }
        var newPage = CollagePage()
        let newVM   = CanvasViewModel()
        let stripFile = "bg_strip_\(pages.count % 3).jpg"
        if persistence.backgroundStripExists(stripFile) {
            newPage.backgroundImageFile = stripFile
            newVM.backgroundImage = persistence.loadBackground(stripFile, journeyId: journeyId)
        }
        pages.append(newPage)
        currentPageIndex = pages.count - 1
        vmCache[newPage.id] = newVM
        editingVM = newVM
        isEditing = true
        saveAsync()
    }

    func deletePage(at index: Int) {
        guard pages.count > 1 else { return }
        vmCache.removeValue(forKey: pages[index].id)
        pages.remove(at: index)
        if currentPageIndex >= pages.count { currentPageIndex = pages.count - 1 }
        if isEditing { isEditing = false }
        saveAsync()
    }

    // MARK: - Private helpers

    private func flushCacheToDisk() {
        print("📓 [flushCacheToDisk] journeyId=\(journeyId) vmCache.count=\(vmCache.count)")
        for (pageId, vm) in vmCache {
            guard let idx = pages.firstIndex(where: { $0.id == pageId }) else {
                print("📓 [flushCacheToDisk] WARN pageId=\(pageId) not found in pages — skipped")
                continue
            }
            print("📓 [flushCacheToDisk] page[\(idx)] id=\(pageId) vm.items=\(vm.items.count) vm.canvasSize=\(vm.canvasSize) vm.backgroundImage=\(vm.backgroundImage != nil ? "YES" : "nil")")
            var snap = persistence.snapshot(from: vm, existing: pages[idx], journeyId: journeyId)
            print("📓 [flushCacheToDisk] page[\(idx)] snapshot.itemSnapshots=\(snap.itemSnapshots.count)")
            let thumb = persistence.generateThumbnail(
                vm: vm, canvasSize: vm.canvasSize, pageId: pageId, journeyId: journeyId)
            print("📓 [flushCacheToDisk] page[\(idx)] generateThumbnail → \(thumb ?? "NIL — canvasSize was \(vm.canvasSize)")")
            if let thumb {
                snap.thumbnailFileName = thumb
            }
            snap.editVersion = pages[idx].editVersion + 1
            pages[idx] = snap
        }
    }

    private func assignBackgroundStrips() {
        var changed = false
        for i in pages.indices {
            guard pages[i].backgroundImageFile == nil else { continue }
            let stripFile = "bg_strip_\(i % 3).jpg"
            if persistence.backgroundStripExists(stripFile) {
                pages[i].backgroundImageFile = stripFile
                changed = true
            }
        }
        if changed { saveAsync() }
    }

    private func saveAsync() {
        let p   = pages
        let jId = journeyId
        Task.detached(priority: .utility) {
            MemoirPersistence.shared.save(p, journeyId: jId)
            // Notificar DESPUÉS de que el guardado termine
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .memoirPageSaved,
                    object: jId
                )
            }
        }
    }
}
