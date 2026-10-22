import SwiftUI
import Photos

@MainActor
final class SwipeDeckViewModel: ObservableObject {
    enum Phase {
        case loading
        case permissionDenied
        case empty            // library has no photos at all
        case picker           // choose a source
        case scanning         // duplicate scan in progress
        case duplicates       // duplicate groups review
        case swiping
        case review
    }

    @Published var phase: Phase = .loading
    @Published private(set) var assets: [PHAsset] = []      // working deck
    @Published var index: Int = 0
    @Published private(set) var history: [SwipeAction] = []
    @Published var albums: [PHAssetCollection] = []
    @Published var isCommitting = false

    // Manual swipe start point (review history remains independent).
    @Published private(set) var startPhotoID: String? = UserDefaults.standard.string(forKey: "swipeStart.assetID")
    @Published private(set) var startPhotoDate: Date? = UserDefaults.standard.object(forKey: "swipeStart.date") as? Date

    // Picker
    @Published private(set) var facets = LibraryFacets()
    @Published private(set) var source: PhotoSource = .all

    // Duplicates
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published var scanProgress: Double = 0

    // Freed space
    @Published private(set) var estimatedFreeBytes: Int64 = 0
    @Published private(set) var freedBytes: Int64 = 0

    // Lifetime analytics
    @Published private(set) var stats = LifetimeStats()

    // Persisted trash queue (survives pause / quit)
    @Published private(set) var pendingTrashIDs: Set<String> = []

    private let service = PhotoLibraryService()
    private let store = ReviewStore()
    private let statsStore = StatsStore()
    private let trashStore = PendingTrashStore()
    private lazy var finder = DuplicateFinder(service: service)
    private var allImages: [PHAsset] = []

    // MARK: Derived

    /// Everything queued for deletion (this run + any leftover from a paused
    /// session), resolved against the current library.
    var pendingTrash: [PHAsset] {
        allImages.filter { pendingTrashIDs.contains($0.localIdentifier) }
    }
    var pendingTrashCount: Int { pendingTrashIDs.count }
    var keptCount: Int { history.filter { $0.decision == .keep }.count }
    var skippedCount: Int { history.filter { $0.decision == .skip }.count }
    var favoritedCount: Int { history.filter { if case .favorite = $0.decision { return true }; return false }.count }
    var albumedCount: Int { history.filter { if case .album = $0.decision { return true }; return false }.count }

    var current: PHAsset? { peek(0) }
    var next: PHAsset? { peek(1) }
    func peek(_ offset: Int) -> PHAsset? {
        let i = index + offset
        return assets.indices.contains(i) ? assets[i] : nil
    }
    var remaining: Int { max(assets.count - index, 0) }
    var progress: Double { assets.isEmpty ? 0 : Double(index) / Double(assets.count) }
    var canUndo: Bool { !history.isEmpty }

    var duplicateTrashCount: Int { duplicateGroups.reduce(0) { $0 + $1.trashIDs.count } }

    // MARK: Bootstrap

    func bootstrap() async {
        let status = service.authorizationStatus()
        switch status {
        case .authorized, .limited:
            await loadLibrary()
        case .notDetermined:
            let s = await service.requestAuthorization()
            if s == .authorized || s == .limited { await loadLibrary() }
            else { phase = .permissionDenied }
        default:
            phase = .permissionDenied
        }
    }

    private func loadLibrary() async {
        phase = .loading
        stats = statsStore.load()
        pendingTrashIDs = trashStore.ids
        allImages = service.fetchAllPhotos()
        albums = service.userAlbums()
        if allImages.isEmpty { phase = .empty; return }
        facets = computeFacets(allImages)
        phase = .picker
    }

    private func computeFacets(_ images: [PHAsset]) -> LibraryFacets {
        var f = LibraryFacets()
        f.total = images.count
        var yearCounts: [Int: Int] = [:]
        let cal = Calendar.current
        for a in images {
            if a.mediaSubtypes.contains(.photoScreenshot) { f.screenshots += 1 }
            if let d = a.creationDate { yearCounts[cal.component(.year, from: d), default: 0] += 1 }
        }
        f.years = yearCounts.map { (year: $0.key, count: $0.value) }.sorted { $0.year > $1.year }
        return f
    }

    // MARK: Source selection

    var startPhotoDescription: String? {
        guard startPhotoID != nil else { return nil }
        return startPhotoDate?.formatted(date: .abbreviated, time: .shortened) ?? "Gekozen foto"
    }

    func clearStartPhoto() {
        startPhotoID = nil
        startPhotoDate = nil
        UserDefaults.standard.removeObject(forKey: "swipeStart.assetID")
        UserDefaults.standard.removeObject(forKey: "swipeStart.date")
    }

    @discardableResult
    func startFromPhoto(_ id: String) -> Bool {
        allImages = service.fetchAllPhotos()
        guard let photo = allImages.first(where: { $0.localIdentifier == id }) else { return false }
        startPhotoID = id
        startPhotoDate = photo.creationDate
        UserDefaults.standard.set(id, forKey: "swipeStart.assetID")
        if let date = photo.creationDate { UserDefaults.standard.set(date, forKey: "swipeStart.date") }
        else { UserDefaults.standard.removeObject(forKey: "swipeStart.date") }
        facets = computeFacets(allImages)
        select(.all)
        return true
    }

    private var imagesFromStartPhoto: [PHAsset] {
        if let id = startPhotoID, let position = allImages.firstIndex(where: { $0.localIdentifier == id }) {
            return Array(allImages[position...])
        }
        if startPhotoID != nil, let date = startPhotoDate {
            return allImages.filter { ($0.creationDate ?? .distantPast) <= date }
        }
        return allImages
    }


    func select(_ source: PhotoSource) {
        self.source = source
        if source.isDuplicates {
            Task { await runScan() }
        } else {
            startDeck(for: source)
        }
    }

    private func startDeck(for source: PhotoSource) {
        service.stopCaching()
        history = []
        index = 0
        estimatedFreeBytes = 0
        freedBytes = 0

        var working = imagesFromStartPhoto.filter { !store.isReviewed($0.localIdentifier) }
        switch source {
        case .all: break
        case .screenshots:
            working = working.filter { $0.mediaSubtypes.contains(.photoScreenshot) }
        case .largest:
            working.sort { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        case .year(let y):
            let cal = Calendar.current
            working = working.filter {
                guard let d = $0.creationDate else { return false }
                return cal.component(.year, from: d) == y
            }
        case .duplicates: break
        }

        assets = working
        if working.isEmpty {
            phase = .review   // shows "nothing left here" state
        } else {
            phase = .swiping
            service.startCaching(Array(working.prefix(20)),
                                 targetSize: CGSize(width: 1080, height: 1080))
        }
    }

    func backToPicker() {
        service.stopCaching()
        facets = computeFacets(allImages)
        history = []
        duplicateGroups = []
        phase = .picker
    }

    func resetProgress() {
        store.reset()
        clearStartPhoto()
        backToPicker()
    }

    func resetStats() {
        statsStore.reset()
        stats = statsStore.load()
    }

    // MARK: Swipe decisions

    func decide(_ decision: Decision) {
        guard let asset = current else { return }
        history.append(SwipeAction(asset: asset, decision: decision))

        switch decision {
        case .favorite:
            store.mark(asset.localIdentifier)
            Task { try? await service.setFavorite(asset, true) }
        case .album(let id, _):
            store.mark(asset.localIdentifier)
            Task { try? await service.add(asset, toAlbumWithLocalIdentifier: id) }
        case .keep:
            store.mark(asset.localIdentifier)
        case .trash:
            store.mark(asset.localIdentifier)
            trashStore.add(asset.localIdentifier)
            pendingTrashIDs.insert(asset.localIdentifier)
        case .skip:
            break   // not persisted — reappears next session
        }
        advance()
    }

    private func advance() {
        if index + 1 >= assets.count {
            index = assets.count
            Task { await computeFreeEstimate() }
            phase = .review
        } else {
            index += 1
        }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        if phase == .review { phase = .swiping }
        index = max(index - 1, 0)
        Haptics.tap(.medium)

        switch last.decision {
        case .favorite:
            store.unmark(last.asset.localIdentifier)
            Task { try? await service.setFavorite(last.asset, false) }
        case .keep, .album:
            store.unmark(last.asset.localIdentifier)
        case .trash:
            store.unmark(last.asset.localIdentifier)
            trashStore.remove(last.asset.localIdentifier)
            pendingTrashIDs.remove(last.asset.localIdentifier)
        case .skip:
            break
        }
    }

    // MARK: Batch selection

    var batchCandidates: [PHAsset] {
        Array(assets.dropFirst(index))
    }

    func queueBatchTrash(_ ids: Set<String>) {
        let selected = batchCandidates.filter { ids.contains($0.localIdentifier) }
        guard !selected.isEmpty else { return }
        for asset in selected {
            let id = asset.localIdentifier
            trashStore.add(id)
            pendingTrashIDs.insert(id)
            store.mark(id)
        }
        finishBatch(Set(selected.map(\.localIdentifier)))
    }

    func addBatchToAlbum(_ ids: Set<String>, albumID: String) async throws {
        let selected = batchCandidates.filter { ids.contains($0.localIdentifier) }
        guard !selected.isEmpty else { return }
        try await service.addBatch(selected, toAlbumWithLocalIdentifier: albumID)
        for asset in selected { store.mark(asset.localIdentifier) }
        finishBatch(Set(selected.map(\.localIdentifier)))
    }

    private func finishBatch(_ ids: Set<String>) {
        // Batch edits create an undo boundary: no stale single-card index/history.
        history.removeAll()
        assets.removeAll { ids.contains($0.localIdentifier) }
        index = min(index, assets.count)
        service.stopCaching()
        if index >= assets.count {
            Task { await computeFreeEstimate() }
            phase = .review
        }
    }

    // MARK: Albums

    func createAlbum(named name: String) async -> (id: String, title: String)? {
        guard let id = try? await service.createAlbum(named: name) else { return nil }
        albums = service.userAlbums()
        return (id, name)
    }

    // MARK: Freed space

    private func computeFreeEstimate() async {
        let assetsToFree = pendingTrash
        let bytes = await Task.detached { [service] in service.totalBytes(of: assetsToFree) }.value
        estimatedFreeBytes = bytes
    }

    // MARK: Commit (swipe deck)

    /// Delete the whole pending-trash queue now. Works mid-run (keep swiping)
    /// or from the review / picker screens.
    func commitPendingTrash(returnToPicker: Bool) async {
        let toDelete = pendingTrash
        guard !toDelete.isEmpty else {
            if returnToPicker { Haptics.success(); backToPicker() }
            return
        }
        isCommitting = true
        defer { isCommitting = false }
        let bytes = await Task.detached { [service] in service.totalBytes(of: toDelete) }.value
        do {
            try await service.deleteAssets(toDelete)   // system confirm sheet
            freedBytes = bytes
            estimatedFreeBytes = 0
            stats = statsStore.record(freed: bytes, deleted: toDelete.count)
            trashStore.clear()
            pendingTrashIDs.removeAll()
            history.removeAll { $0.decision == .trash }
            allImages = service.fetchAllPhotos()
            Haptics.success()
            if returnToPicker { backToPicker() }
        } catch {
            Haptics.warning()   // user canceled system delete sheet
        }
    }

    /// Back-compat for the review screen.
    func commitDeletions() async { await commitPendingTrash(returnToPicker: true) }

    // MARK: Duplicates

    private func runScan() async {
        phase = .scanning
        scanProgress = 0
        let input = allImages.filter { !store.isReviewed($0.localIdentifier) }
        let groups = await finder.scan(input) { [weak self] p in self?.scanProgress = p }
        duplicateGroups = groups
        phase = .duplicates
        Haptics.success()
    }

    func toggleTrash(group: DuplicateGroup.ID, asset id: String) {
        guard let gi = duplicateGroups.firstIndex(where: { $0.id == group }) else { return }
        var g = duplicateGroups[gi]
        if g.trashIDs.contains(id) {
            g.trashIDs.remove(id)
        } else {
            // keep at least one
            if g.trashIDs.count < g.assets.count - 1 { g.trashIDs.insert(id) }
            else { Haptics.warning(); return }
        }
        duplicateGroups[gi] = g
        Haptics.soft()
    }

    func commitDuplicates() async {
        let ids = Set(duplicateGroups.flatMap { $0.trashIDs })
        let toDelete = duplicateGroups.flatMap { $0.assets }.filter { ids.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { backToPicker(); return }
        isCommitting = true
        defer { isCommitting = false }
        let bytes = await Task.detached { [service] in service.totalBytes(of: toDelete) }.value
        do {
            try await service.deleteAssets(toDelete)
            toDelete.forEach { store.mark($0.localIdentifier) }
            freedBytes = bytes
            estimatedFreeBytes = bytes
            stats = statsStore.record(freed: bytes, deleted: toDelete.count, duplicates: toDelete.count)
            allImages = service.fetchAllPhotos()
            duplicateGroups = []
            Haptics.success()
            backToPicker()
        } catch {
            Haptics.warning()
        }
    }
}
