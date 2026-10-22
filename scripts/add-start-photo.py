from pathlib import Path

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("Expected one source anchor: " + old[:100])
    return text.replace(old, new, 1)

vm_path = Path("PhotoSwipe/PhotoSwipe/ViewModels/SwipeDeckViewModel.swift")
view_path = Path("PhotoSwipe/PhotoSwipe/Views/SourcePickerView.swift")
vm = vm_path.read_text()
view = view_path.read_text()
vm_fields = '    // Manual swipe start point (review history remains independent).\n    @Published private(set) var startPhotoID: String? = UserDefaults.standard.string(forKey: "swipeStart.assetID")\n    @Published private(set) var startPhotoDate: Date? = UserDefaults.standard.object(forKey: "swipeStart.date") as? Date\n'
vm_methods = '    var startPhotoDescription: String? {\n        guard startPhotoID != nil else { return nil }\n        return startPhotoDate?.formatted(date: .abbreviated, time: .shortened) ?? "Gekozen foto"\n    }\n\n    func clearStartPhoto() {\n        startPhotoID = nil\n        startPhotoDate = nil\n        UserDefaults.standard.removeObject(forKey: "swipeStart.assetID")\n        UserDefaults.standard.removeObject(forKey: "swipeStart.date")\n    }\n\n    @discardableResult\n    func startFromPhoto(_ id: String) -> Bool {\n        allImages = service.fetchAllPhotos()\n        guard let photo = allImages.first(where: { $0.localIdentifier == id }) else { return false }\n        startPhotoID = id\n        startPhotoDate = photo.creationDate\n        UserDefaults.standard.set(id, forKey: "swipeStart.assetID")\n        if let date = photo.creationDate { UserDefaults.standard.set(date, forKey: "swipeStart.date") }\n        else { UserDefaults.standard.removeObject(forKey: "swipeStart.date") }\n        facets = computeFacets(allImages)\n        select(.all)\n        return true\n    }\n\n    private var imagesFromStartPhoto: [PHAsset] {\n        if let id = startPhotoID, let position = allImages.firstIndex(where: { $0.localIdentifier == id }) {\n            return Array(allImages[position...])\n        }\n        if startPhotoID != nil, let date = startPhotoDate {\n            return allImages.filter { ($0.creationDate ?? .distantPast) <= date }\n        }\n        return allImages\n    }\n\n'
view_controls = '    private var startPointControls: some View {\n        VStack(alignment: .leading, spacing: 10) {\n            PhotosPicker(selection: $startPhoto, matching: .images) {\n                Label("Start vanaf een foto", systemImage: "photo.on.rectangle")\n                    .frame(maxWidth: .infinity)\n            }\n            .buttonStyle(.borderedProminent)\n            .tint(Theme.album)\n            Text("Swipen gaat van nieuw naar oud. Kies je startfoto: nieuwere foto\'s worden overgeslagen, zonder ze te beoordelen of te verwijderen.")\n                .font(.caption)\n                .foregroundStyle(Theme.textDim)\n            if let description = vm.startPhotoDescription {\n                Text("Actief startpunt: \\(description)")\n                    .font(.caption.weight(.semibold))\n                    .foregroundStyle(.white)\n                Button("Startpunt wissen — beoordelingen behouden") { vm.clearStartPhoto() }\n                    .font(.caption)\n                Text("Wis het startpunt om ook nieuwe foto\'s weer te zien. De duplicatenscan blijft de hele bibliotheek controleren.")\n                    .font(.caption2)\n                    .foregroundStyle(Theme.textDim)\n            }\n        }\n        .padding(14)\n        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))\n    }\n\n'
view_events = '        .onChange(of: startPhoto) { _, item in\n            guard let item else { return }\n            defer { startPhoto = nil }\n            guard let id = item.itemIdentifier, vm.startFromPhoto(id) else {\n                startPhotoError = true\n                return\n            }\n        }\n        .alert("Startfoto niet beschikbaar", isPresented: $startPhotoError) {\n            Button("OK", role: .cancel) {}\n        } message: {\n            Text("Deze foto is niet toegankelijk voor de app. Geef volledige fototoegang in Instellingen of kies een toegestane foto.")\n        }\n'

if "// Manual swipe start point" not in vm:
    vm = replace_once(vm, "    // Picker\n", vm_fields + "\n    // Picker\n")
    vm = replace_once(vm, "    // MARK: Source selection\n", "    // MARK: Source selection\n\n" + vm_methods)
    vm = replace_once(vm, "var working = allImages.filter { !store.isReviewed($0.localIdentifier) }", "var working = imagesFromStartPhoto.filter { !store.isReviewed($0.localIdentifier) }")
    vm = replace_once(vm, "        store.reset()\n", "        store.reset()\n        clearStartPhoto()\n")
if "private var startPointControls" not in view:
    view = replace_once(view, "import SwiftUI\n", "import SwiftUI\nimport PhotosUI\n")
    view = replace_once(view, "    @State private var showStats = false\n", "    @State private var showStats = false\n    @State private var startPhoto: PhotosPickerItem?\n    @State private var startPhotoError = false\n")
    view = replace_once(view, "                title\n\n", "                title\n                startPointControls\n\n")
    view = replace_once(view, "        .scrollIndicators(.hidden)", view_events + "        .scrollIndicators(.hidden)")
    view = replace_once(view, "    private var title: some View {", view_controls + "    private var title: some View {")
vm_path.write_text(vm)
view_path.write_text(view)
