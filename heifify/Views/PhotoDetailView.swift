import SwiftUI
import Photos

struct PhotoDetailView: View {
    let asset: PHAsset
    @StateObject private var vm = PhotoDetailViewModel()
    @State private var showExif = false
    @State private var showConvertSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffsetY: CGFloat = 0
    private var dragProgress: CGFloat { max(0, min(1, dragOffsetY / 300)) }
    var onClose: (() -> Void)? = nil
    var matchedNamespace: Namespace.ID? = nil
    var matchedID: String? = nil
    var onConverted: (() -> Void)? = nil
    @State private var hideChrome: Bool = false
    @State private var zoomScale: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panAccumulated: CGSize = .zero
    @State private var gesturesEnabled: Bool = true

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - dragProgress)).ignoresSafeArea()
            if let ui = vm.previewImage {
                // Pure SwiftUI Image (HDR removed)
                let visual = Image(uiImage: ui).resizable().scaledToFit()
                    .offset(x: panOffset.width, y: panOffset.height + dragOffsetY)
                    .scaleEffect(zoomScale * (1 - dragProgress * 0.12))
                    .cornerRadius(dragProgress * 18)
                    .shadow(color: .black.opacity(dragProgress * 0.3), radius: dragProgress * 18)
                let pinching = MagnificationGesture()
                    .onChanged { value in
                        guard gesturesEnabled else { return }
                        let new = baseZoom * value
                        zoomScale = min(max(1, new), 4)
                    }
                    .onEnded { _ in baseZoom = zoomScale }
                let panning = DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard gesturesEnabled && zoomScale > 1 else { return }
                        let factor: CGFloat = 0.3
                        panOffset = CGSize(
                            width: panAccumulated.width + value.translation.width * factor,
                            height: panAccumulated.height + value.translation.height * factor
                        )
                    }
                    .onEnded { value in
                        guard gesturesEnabled && zoomScale > 1 else { return }
                        let factor: CGFloat = 0.3
                        panAccumulated.width += value.translation.width * factor
                        panAccumulated.height += value.translation.height * factor
                    }
                Group {
                    if let ns = matchedNamespace, let id = matchedID {
                        visual.matchedGeometryEffect(id: id, in: ns)
                    } else { visual }
                }
                .gesture(pinching)
                .highPriorityGesture(panning)
                .simultaneousGesture(dragGesture)
                .onTapGesture(count: 2, perform: toggleDoubleTap)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { hideChrome.toggle() } }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black.opacity(Double(hideChrome ? 0 : (1 - dragProgress * 0.9))), for: .navigationBar)
        .toolbar { ToolbarItem(placement: .principal) { Text("预览").foregroundStyle(.white).opacity(hideChrome ? 0 : 1) } }
        .task { await vm.load(asset: asset) }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showExif) { exifSheet }
        .sheet(isPresented: $showConvertSheet) { convertSheet }
        .overlay { if vm.isConverting { blockingProgress } }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard !showConvertSheet && !showExif && zoomScale <= 1.01 else { return }
                dragOffsetY = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !showConvertSheet && !showExif && zoomScale <= 1.01 else { return }
                let predicted = max(value.translation.height, value.predictedEndTranslation.height)
                if predicted > 140 { if let onClose { onClose() } else { dismiss() } }
                else if value.translation.height < -90 { showConvertSheet = true; dragOffsetY = 0 }
                else { withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) { dragOffsetY = 0 } }
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 36, height: 4)
            HStack {
                Spacer()
                Button { showExif = true } label: { Image(systemName: "info.circle").font(.title2) }
                Spacer()
                Button { showConvertSheet = true } label: { Image(systemName: "slider.horizontal.3").font(.title2) }
                Spacer()
            }
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.8))
        }
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .opacity((hideChrome ? 0 : 1) * Double(1 - dragProgress * 2))
        .allowsHitTesting(!hideChrome && dragProgress < 0.1)
    }

    private var exifSheet: some View {
        NavigationStack {
            List(vm.exif.keys.sorted(), id: \.self) { key in
                HStack { Text(key); Spacer(); Text(vm.exif[key] ?? "").foregroundStyle(.secondary) }
            }
            .navigationTitle("EXIF")
        }
        .presentationDetents([.medium, .large])
    }

    private var convertSheet: some View {
        NavigationStack {
            Form {
                Section("信息") {
                    HStack { Text("原始大小"); Spacer(); Text(vm.originalSizeText) }
                    HStack { Text("HEIF 估算"); Spacer(); Text(vm.estimatedSizeText ?? "—") }
                }
                Section("保存") {
                    Picker("保存方式", selection: $vm.saveMode) {
                        Text("保存到相册").tag(PhotoDetailViewModel.SaveMode.addNew)
                        Text("覆盖当前").tag(PhotoDetailViewModel.SaveMode.overwrite)
                    }
                    .pickerStyle(.segmented)
                    Text("覆盖当前会以" + "非破坏性编辑" + "方式应用，原片仍可在相册中还原。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("参数") {
                    HStack(spacing: 12) {
                        Text("压缩比")
                        Slider(value: $vm.quality, in: 0.3...1.0, step: 0.05)
                        Text(String(format: "%.2f", vm.quality)).monospacedDigit()
                    }
                    HStack {
                        Text("色深")
                        Picker("色深", selection: $vm.depth) {
                            Text("8-bit").tag(ImageBitDepth.eightBit)
                            Text("10-bit(若支持)").tag(ImageBitDepth.tenBit)
                        }.pickerStyle(.segmented)
                    }
                }
                Section {
                    Button("开始转换") {
                        vm.convertAndSaveHEIF { success in
                            if success {
                                // 先关闭预览以触发 matchedGeometryEffect 缩回
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                                    onClose?()
                                }
                                // 再刷新列表，避免中断动画
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    onConverted?()
                                }
                            }
                        }
                    }
                        .buttonStyle(.borderedProminent)
                    if let err = vm.errorMessage { Text(err).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("HEIF 转换")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: vm.quality) { _ in vm.updateEstimate() }
            .onChange(of: vm.depth) { _ in vm.updateEstimate() }
        }
        .presentationDetents([.height(320), .large])
    }

    private var blockingProgress: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("正在转换…")
                    .foregroundStyle(.white)
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .allowsHitTesting(true)
    }

    private func toggleDoubleTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoomScale > 1.01 { zoomScale = 1; baseZoom = 1; panOffset = .zero; panAccumulated = .zero }
            else { zoomScale = 2.5; baseZoom = 2.5 }
        }
    }
}
