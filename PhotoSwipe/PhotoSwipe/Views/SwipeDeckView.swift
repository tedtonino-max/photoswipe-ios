import SwiftUI
import Photos

/// The swiping surface. Header + action bar are pinned via `safeAreaInset`, so
/// the layout adapts to every phone (notch, Dynamic Island, home-indicator)
/// without clipping. Left = trash, right = keep, up = favorite, album button =
/// album sheet.
struct SwipeDeckView: View {
    @ObservedObject var vm: SwipeDeckViewModel
    @State private var drag: CGSize = .zero
    @State private var showAlbumSheet = false
    @State private var showBatch = false
    @State private var zoomScale: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var pinching = false
    @State private var pinchStartedAtNormal = false
    @State private var suppressSwipeUntil: Date = .distantPast

    var body: some View {
        deck
            .fullScreenCover(isPresented: $showBatch) {
                PhotoSwipeBatchView(vm: vm)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .sheet(isPresented: $showAlbumSheet) {
                AlbumPickerView(vm: vm) { decision in
                    showAlbumSheet = false
                    fling(.up, decision: decision)
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
            }
    }

    // MARK: Header (premium / techy)

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Button { Haptics.tap(); vm.backToPicker() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .buttonStyle(PressableStyle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.source.title.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(Theme.textDim)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(vm.remaining)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(value: Double(vm.remaining)))
                            .animation(.snappy(duration: 0.35), value: vm.remaining)
                        Text("/ \(vm.assets.count)")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                    }
                    .fixedSize()
                }
                Spacer(minLength: 12)
                if vm.pendingTrashCount > 0 { deleteBatchButton }
                Button {
                openBatch()
            } label: {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            undoButton
            }
            progressBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial.opacity(0.0)) // keep aurora visible
    }

    /// Delete everything swiped-to-trash so far, without finishing the run.
    private var deleteBatchButton: some View {
        Button {
            Haptics.tap(.rigid)
            Task { await vm.commitPendingTrash(returnToPicker: false) }
        } label: {
            HStack(spacing: 5) {
                if vm.isCommitting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "trash.fill").font(.system(size: 13, weight: .bold))
                }
                Text("\(vm.pendingTrashCount)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(vm.pendingTrashCount)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13).frame(height: 44)
            .background(Theme.gradient(Theme.trash, Theme.trash2), in: Capsule())
            .shadow(color: Theme.trash.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .disabled(vm.isCommitting)
        .animation(.snappy, value: vm.pendingTrashCount)
    }

    private var undoButton: some View {
        Button {
            Haptics.tap(.medium)
            vm.undo()
            withAnimation(.cardSpring) { drag = .zero }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
        }
        .buttonStyle(PressableStyle())
        .disabled(!vm.canUndo)
        .opacity(vm.canUndo ? 1 : 0.3)
        .animation(.snappy, value: vm.canUndo)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(Theme.gradient(Theme.album, Theme.keep))
                    .frame(width: max(6, geo.size.width * vm.progress))
                    .shadow(color: Theme.keep.opacity(0.4), radius: 6)
                    .animation(.snappy(duration: 0.4), value: vm.progress)
            }
        }
        .frame(height: 5)
    }

    // MARK: Deck

    private var deck: some View {
        ZStack {
            ForEach(Array(stride(from: 2, through: 1, by: -1)), id: \.self) { depth in
                if let asset = vm.peek(depth) {
                    PhotoCardView(asset: asset, isTop: false)
                        .scaleEffect(1 - CGFloat(depth) * 0.05)
                        .offset(y: CGFloat(depth) * 14)
                        .opacity(depth == 2 ? 0.5 : 0.85)
                        .id(asset.localIdentifier)
                }
            }
            if let current = vm.current {
                PhotoCardView(asset: current, translation: drag, isTop: true, zoomScale: zoomScale, zoomOffset: zoomOffset)
                    .id(current.localIdentifier)
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width / 16)), anchor: .bottom)
                    .gesture(dragGesture)
                    .simultaneousGesture(zoomGesture)
                    .onTapGesture(count: 2) {
                        suppressSwipeUntil = Date().addingTimeInterval(0.5)
                        withAnimation(.cardSpring) { resetZoom() }
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.cardSpring, value: vm.index)
        .onChange(of: vm.current?.localIdentifier) { _, _ in resetZoom() }
    }

    private func resetZoom() {
        zoomScale = 1
        zoomBase = 1
        zoomOffset = .zero
        panBase = .zero
        drag = .zero
        pinching = false
    }

    private func openBatch() {
        resetZoom()
        suppressSwipeUntil = Date().addingTimeInterval(0.5)
        showBatch = true
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !pinching { pinchStartedAtNormal = zoomBase <= 1.01 }
                pinching = true
                drag = .zero
                suppressSwipeUntil = Date().addingTimeInterval(0.5)
                zoomScale = min(5, max(1, zoomBase * value.magnification))
                if zoomScale <= 1.01 { zoomOffset = .zero; panBase = .zero }
            }
            .onEnded { value in
                let openGrid = pinchStartedAtNormal && value.magnification < 0.78
                zoomBase = zoomScale
                pinching = false
                suppressSwipeUntil = Date().addingTimeInterval(0.5)
                if openGrid { openBatch() }
                else if zoomScale < 1.05 {
                    withAnimation(.cardSpring) { resetZoom() }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !pinching else { return }
                if zoomScale > 1.01 {
                    let limit = max(0, (zoomScale - 1) * 180)
                    zoomOffset = CGSize(
                        width: min(limit, max(-limit, panBase.width + value.translation.width)),
                        height: min(limit, max(-limit, panBase.height + value.translation.height))
                    )
                    drag = .zero
                } else if Date() >= suppressSwipeUntil {
                    drag = value.translation
                }
            }
            .onEnded { value in
                guard !pinching, zoomScale <= 1.01,
                      Date() >= suppressSwipeUntil, !showBatch else {
                    panBase = zoomOffset
                    drag = .zero
                    return
                }
                let t = value.translation
                if t.width > Theme.swipeThreshold {
                    fling(.right, decision: .keep)
                } else if t.width < -Theme.swipeThreshold {
                    fling(.left, decision: .trash)
                } else if t.height < -Theme.swipeThreshold {
                    fling(.up, decision: .favorite)
                } else if t.height > Theme.swipeThreshold {
                    fling(.down, decision: .skip)
                } else {
                    Haptics.soft()
                    withAnimation(.cardSpring) { drag = .zero }
                }
            }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 18) {
            actionButton("trash", Theme.trash, Theme.trash2) { fling(.left, decision: .trash) }
            actionButton("rectangle.stack.badge.plus", Theme.album, Theme.album2, big: false) {
                Haptics.tap(); showAlbumSheet = true
            }
            actionButton("star.fill", Theme.favorite, Theme.favorite2, big: false) { fling(.up, decision: .favorite) }
            actionButton("heart.fill", Theme.keep, Theme.keep2) { fling(.right, decision: .keep) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func actionButton(_ icon: String, _ c1: Color, _ c2: Color, big: Bool = true,
                              action: @escaping () -> Void) -> some View {
        let size: CGFloat = big ? 64 : 56
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.gradient(c1, c2))
                .frame(width: size, height: size)
                .background(
                    ZStack {
                        Circle().fill(Theme.card)
                        Circle().fill(c1.opacity(0.10))
                    }
                )
                .overlay(Circle().strokeBorder(c1.opacity(0.45), lineWidth: 1.5))
                .shadow(color: c1.opacity(0.30), radius: 12, y: 5)
        }
        .buttonStyle(PressableStyle(scale: 0.86))
    }

    // MARK: Fling

    private enum FlingDir { case left, right, up, down }

    private func fling(_ dir: FlingDir, decision: Decision) {
        switch decision {
        case .trash: Haptics.tap(.rigid)
        case .favorite: Haptics.success()
        case .skip: Haptics.soft()
        default: Haptics.tap(.light)
        }
        let target: CGSize
        switch dir {
        case .left:  target = CGSize(width: -760, height: 80)
        case .right: target = CGSize(width: 760, height: 80)
        case .up:    target = CGSize(width: drag.width, height: -960)
        case .down:  target = CGSize(width: drag.width, height: 960)
        }
        withAnimation(.fling) { drag = target }
        // Let the card fly off before committing the decision and resetting.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            vm.decide(decision)
            drag = .zero
        }
    }
}


@MainActor
private struct PhotoSwipeBatchView: View {
    @ObservedObject var vm: SwipeDeckViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var showingAlbums = false
    @State private var confirmingTrash = false
    @State private var busy = false
    @State private var errorMessage = ""
    @State private var showingError = false
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 5)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(vm.batchCandidates, id: \.localIdentifier) { asset in
                        Button {
                            toggle(asset.localIdentifier)
                        } label: {
                            PhotoSwipeBatchThumbnail(
                                asset: asset,
                                selected: selected.contains(asset.localIdentifier)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                .padding(8)
            }
            .navigationTitle("\(selected.count) geselecteerd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Gereed") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Alles selecteren") {
                            selected = Set(vm.batchCandidates.map(\.localIdentifier))
                        }
                        Button("Selectie wissen") { selected.removeAll() }
                        Button("Reeks tussen eerste en laatste selecteren") {
                            selectRange()
                        }
                        .disabled(selected.count < 2)
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) { batchBar }
            .sheet(isPresented: $showingAlbums) {
                AlbumPickerView(vm: vm) { decision in
                    guard case let .album(id, _) = decision else { return }
                    showingAlbums = false
                    moveToAlbum(id)
                }
            }
            .confirmationDialog(
                "\(selected.count) foto's klaarzetten voor verwijderen?",
                isPresented: $confirmingTrash,
                titleVisibility: .visible
            ) {
                Button("In verwijderwachtrij zetten", role: .destructive) {
                    vm.queueBatchTrash(selected)
                    dismiss()
                }
                Button("Annuleren", role: .cancel) {}
            } message: {
                Text("Ze worden nog niet verwijderd. Gebruik daarna de prullenbak met het aantal voor de systeembevestiging.")
            }
            .alert("Albumactie mislukt", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private var batchBar: some View {
        VStack(spacing: 10) {
            Text("Resterende foto's in de huidige wachtrij. Batchacties wissen de eerdere Undo-geschiedenis.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button {
                    confirmingTrash = true
                } label: {
                    Label("Prullenbak", systemImage: "trash")
                }
                .tint(.red)
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Button {
                        showingAlbums = true
                    } label: {
                        Label("Album", systemImage: "folder.badge.plus")
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(selected.isEmpty || busy)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) }
        else { selected.insert(id) }
    }

    private func selectRange() {
        let candidates = vm.batchCandidates
        let indices = candidates.indices.filter {
            selected.contains(candidates[$0].localIdentifier)
        }
        guard let first = indices.first, let last = indices.last else { return }
        selected = Set(candidates[first...last].map(\.localIdentifier))
    }

    private func moveToAlbum(_ id: String) {
        guard !busy else { return }
        busy = true
        let ids = selected
        Task { @MainActor in
            do {
                try await vm.addBatchToAlbum(ids, albumID: id)
                busy = false
                dismiss()
            } catch {
                busy = false
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

private struct PhotoSwipeBatchThumbnail: View {
    let asset: PHAsset
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        ProgressView()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.blue : Color.white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .padding(6)
            }
            .overlay {
                Rectangle().stroke(selected ? Color.blue : Color.clear, lineWidth: 3)
            }
            .clipped()
            .accessibilityLabel("Foto")
            .accessibilityValue(selected ? "Geselecteerd" : "Niet geselecteerd")
            .task(id: asset.localIdentifier) {
                image = nil
                let loader = PhotoLibraryService()
                let result = await loader.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 360, height: 360),
                    contentMode: .aspectFill
                )
                if !Task.isCancelled { image = result }
            }
    }
}
