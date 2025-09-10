import SwiftUI
import Photos
import MapKit

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
    @State private var containerSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - dragProgress)).ignoresSafeArea()
            if let ui = vm.previewImage {
                // Pure SwiftUI Image (HDR removed). Use fill when zooming for edge-to-edge.
                let visual = Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: (zoomScale > 1.05 ? .fill : .fit))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .offset(x: panOffset.width, y: panOffset.height + dragOffsetY)
                    .scaleEffect(zoomScale * (1 - dragProgress * 0.12), anchor: .center)
                    .cornerRadius(dragProgress * 18)
                    .shadow(color: .black.opacity(dragProgress * 0.3), radius: dragProgress * 18)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { containerSize = proxy.size }
                    })
                let pinching = MagnificationGesture()
                    .onChanged { value in
                        guard gesturesEnabled else { return }
                        // Deadzone & damping
                        let factor: CGFloat = 0.35
                        let threshold: CGFloat = 0.005 // 0.5% before scaling
                        let delta = value - 1
                        let effectiveDelta: CGFloat
                        if abs(delta) <= threshold { effectiveDelta = 0 }
                        else { effectiveDelta = (delta - threshold * (delta > 0 ? 1 : -1)) }
                        let adjusted = 1 + effectiveDelta * factor
                        let new = baseZoom * adjusted
                        zoomScale = min(max(1, new), 5)
                    }
                    .onEnded { _ in baseZoom = zoomScale }
                let panning = DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard gesturesEnabled && zoomScale > 1 else { return }
                        let factor: CGFloat = 0.5
                        let proposed = CGSize(
                            width: panAccumulated.width + value.translation.width * factor,
                            height: panAccumulated.height + value.translation.height * factor
                        )
                        panOffset = clampPan(proposed: proposed, imageSize: ui.size, container: containerSize, scale: zoomScale)
                    }
                    .onEnded { value in
                        guard gesturesEnabled && zoomScale > 1 else { return }
                        let factor: CGFloat = 0.5
                        let proposed = CGSize(
                            width: panAccumulated.width + value.translation.width * factor,
                            height: panAccumulated.height + value.translation.height * factor
                        )
                        let clamped = clampPan(proposed: proposed, imageSize: ui.size, container: containerSize, scale: zoomScale)
                        panAccumulated = clamped
                        panOffset = clamped
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
        .sheet(isPresented: $showExif) { metadataSheet }
        .sheet(isPresented: $showConvertSheet) { convertSheet }
        .overlay { if vm.isConverting { blockingProgress } }
        .overlay(alignment: .bottom) {
            if let msg = vm.toastMessage {
                ToastView(message: msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { vm.toastMessage = nil } }
                    }
            }
        }
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

    @State private var metaTab: Int = 0
    private var metadataSheet: some View {
        NavigationStack {
            VStack {
                Picker("分类", selection: $metaTab) {
                    Text("通用").tag(0)
                    Text("Exif").tag(1)
                    Text("TIFF").tag(2)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                List {
                    if metaTab == 0 {
                        ForEach(generalDisplay(), id: \.0) { k, v in infoRow(k, v) }
                        if let loc = vm.location {
                            Section("定位") {
                                let region = MKCoordinateRegion(center: loc.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                                Map(coordinateRegion: .constant(region)).frame(height: 200).listRowInsets(EdgeInsets())
                                infoRow("纬度", String(format: "%.5f", loc.coordinate.latitude))
                                infoRow("经度", String(format: "%.5f", loc.coordinate.longitude))
                            }
                        }
                    } else if metaTab == 1 {
                        ForEach(exifDisplay(), id: \.0) { k, v in infoRow(k, v) }
                    } else {
                        ForEach(tiffDisplay(), id: \.0) { k, v in infoRow(k, v) }
                    }
                }
            }
            .navigationTitle("元数据信息")
        }
        .presentationDetents([.medium, .large])
    }

    private func generalDisplay() -> [(String,String)] {
        let order = ["颜色模式","深度","DPI高度","DPI宽度","Headroom","方向","像素高度","像素宽度","首选图像","描述文件名称"]
        var res: [(String,String)] = []
        for k in order { if let v = vm.general[k] { res.append((k,v)) } }
        let others = vm.general.keys.filter { !order.contains($0) }.sorted()
        for k in others { if let v = vm.general[k] { res.append((k,v)) } }
        return res
    }

    private func exifDisplay() -> [(String,String)] {
        let m = PhotoDetailViewModel.exifKeyMap
        // Preferred order roughly based on参考图
        let order = ["FNumber","BrightnessValue","ColorSpace","CompositeImage","DateTimeDigitized","DateTimeOriginal","ExifVersion","ExposureBiasValue","ExposureMode","ExposureProgram","ExposureTime","Flash","ApertureValue","FocalLength","FocalLenIn35mmFilm","ISOSpeedRatings","PhotographicSensitivity","LensMake","LensModel","LensSpecification","MeteringMode","OffsetTime","OffsetTimeDigitized","OffsetTimeOriginal","PixelXDimension","PixelYDimension","SceneType","SensingMethod","ShutterSpeedValue","SubjectArea","SubsecTimeDigitized","SubsecTimeOriginal","WhiteBalance"]
        var res: [(String,String)] = []
        for key in order { if let v = vm.exif[key] { res.append((m[key] ?? key, prettyValue(forKey: key, value: v, category: "EXIF"))) } }
        let remaining = vm.exif.keys.filter { !order.contains($0) }.sorted { (m[$0] ?? $0) < (m[$1] ?? $1) }
        for k in remaining { if let v = vm.exif[k] { res.append((m[k] ?? k, prettyValue(forKey: k, value: v, category: "EXIF"))) } }
        return res
    }

    private func tiffDisplay() -> [(String,String)] {
        let m = PhotoDetailViewModel.tiffKeyMap
        let order = ["DateTime","HostComputer","Make","Model","Orientation","ResolutionUnit","Software","TileLength","TileWidth","XResolution","YResolution"]
        var res: [(String,String)] = []
        for key in order { if let v = vm.tiff[key] { res.append((m[key] ?? key, prettyValue(forKey: key, value: v, category: "TIFF"))) } }
        let remaining = vm.tiff.keys.filter { !order.contains($0) }.sorted { (m[$0] ?? $0) < (m[$1] ?? $1) }
        for k in remaining { if let v = vm.tiff[k] { res.append((m[k] ?? k, prettyValue(forKey: k, value: v, category: "TIFF"))) } }
        return res
    }

    // MARK: - Pretty formatting helpers
    private func prettyValue(forKey key: String, value: String, category: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // 统一日期时间格式
        if key.lowercased().contains("datetime") || key == "DateTime" {
            if let formatted = formatDateString(trimmed) { return formatted }
        }

        // ISO/数值型：去掉括号和多余空格
        if ["ISOSpeedRatings","PhotographicSensitivity","PixelXDimension","PixelYDimension","SubjectArea"].contains(key) {
            return normalizeNumericList(trimmed, preferFirst: key == "ISOSpeedRatings" || key == "PhotographicSensitivity")
        }

        if key == "ExposureTime" { return formatExposureTime(trimmed) }
        if key == "ShutterSpeedValue" { return formatShutterSpeedValue(trimmed) }
        if key == "FNumber" || key == "ApertureValue" { return formatAperture(trimmed) }
        if key == "FocalLength" || key == "FocalLenIn35mmFilm" { return formatFocal(trimmed, key: key) }
        if key == "LensSpecification" { return formatLensSpec(trimmed) }
        if key == "Flash" { return formatFlash(trimmed) }

        return trimmed.replacingOccurrences(of: "(\n|\t)", with: " ", options: .regularExpression)
    }

    private func formatDateString(_ s: String) -> String? {
        let patterns = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss"
        ]
        for p in patterns {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = p
            if let d = df.date(from: s) {
                let out = DateFormatter(); out.locale = Locale(identifier: "zh_CN"); out.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
                return out.string(from: d)
            }
        }
        return nil
    }

    private func normalizeNumericList(_ s: String, preferFirst: Bool) -> String {
        // remove parentheses/brackets and split by non-number separators
        let cleaned = s.replacingOccurrences(of: "[(){}]", with: "", options: .regularExpression)
        let nums = cleaned.components(separatedBy: CharacterSet(charactersIn: ", \\n\\t")).filter { !$0.isEmpty }
        if preferFirst, let first = nums.first { return first }
        return nums.joined(separator: ", ")
    }

    private func formatExposureTime(_ s: String) -> String {
        if let val = Double(s) {
            if val >= 1 { return String(format: "%.0f s", val) }
            else { return "1/\(Int(round(1/val))) s" }
        }
        return s
    }

    private func formatShutterSpeedValue(_ s: String) -> String {
        if let sv = Double(s) {
            let t = pow(2.0, -sv)
            if t >= 1 { return String(format: "%.0f s", t) }
            else { return "1/\(max(1, Int(round(1/t)))) s" }
        }
        return s
    }

    private func formatAperture(_ s: String) -> String {
        if let v = Double(s) { return String(format: "f/%.1f", v) }
        return s
    }

    private func formatFocal(_ s: String, key: String) -> String {
        if let v = Double(s) {
            if key == "FocalLenIn35mmFilm" { return String(format: "%.0f mm (等效35mm)", v) }
            return String(format: "%.0f mm", v)
        }
        return s
    }

    private func formatLensSpec(_ s: String) -> String {
        // Expect 4 numbers: flMin, flMax, fMin, fMax
        let numbers = s.replacingOccurrences(of: "[(){}]", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ", \\n\\t "))
            .compactMap { Double($0) }
        if numbers.count >= 4 {
            return String(format: "%.0f–%.0f mm, f/%.1f–f/%.1f", numbers[0], numbers[1], numbers[2], numbers[3])
        }
        return s
    }

    private func formatFlash(_ s: String) -> String {
        if let v = Int(s) {
            switch v {
            case 0: return "关闭，未闪光"
            case 1: return "开启/触发"
            default: return "代码 \(v)"
            }
        }
        return s
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private var convertSheet: some View {
        NavigationStack {
                ConversionOptionsView(
                    quality: $vm.quality,
                    depth: $vm.depth,
                    saveMode: $vm.saveMode,
                    showInfo: true,
                    originalSizeText: vm.originalSizeText,
                    estimatedSizeText: vm.estimatedSizeText,
                    convertButtonTitle: "开始转换",
                    onStart: {
                    vm.convertLikeFinderAndSave { success in
                        if success {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { onClose?() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onConverted?() }
                        }
                    }
                }
            )
            .navigationTitle("HEIF 转换")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: vm.quality) { _ in vm.updateEstimate() }
            .onChange(of: vm.depth) { _ in vm.updateEstimate() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    private struct ToastView: View {
        let message: String
        var body: some View {
            Text(message)
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.8))
                .clipShape(Capsule())
                .padding(.bottom, 24)
        }
    }

    private func toggleDoubleTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoomScale > 1.01 { zoomScale = 1; baseZoom = 1; panOffset = .zero; panAccumulated = .zero }
            else { zoomScale = 2.5; baseZoom = 2.5 }
        }
    }

    // Clamp pan so that image edges do not cross inside the screen bounds when zoomed.
    private func clampPan(proposed: CGSize, imageSize: CGSize, container: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1, container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        // Base scale to fill container at scale 1 (like .fill)
        let fillScale = max(container.width / imageSize.width, container.height / imageSize.height)
        let displayedWidth = imageSize.width * fillScale * scale
        let displayedHeight = imageSize.height * fillScale * scale
        let maxOffsetX = max(0, (displayedWidth - container.width) / 2)
        let maxOffsetY = max(0, (displayedHeight - container.height) / 2)
        let clampedX = min(max(proposed.width, -maxOffsetX), maxOffsetX)
        let clampedY = min(max(proposed.height, -maxOffsetY), maxOffsetY)
        return CGSize(width: clampedX, height: clampedY)
    }
}
