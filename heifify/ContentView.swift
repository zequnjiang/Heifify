//
//  ContentView.swift
//  heifify
//
//  Created by Ozawa on 2025/9/9.
//

import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var vm = PhotoLibraryViewModel()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private let spacing: CGFloat = 2
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    @State private var showBatchConvertSheet = false
    @State private var batchQuality: Double = 0.8
    @State private var batchDepth: ImageBitDepth = .eightBit
    @State private var batchSaveMode: PhotoDetailViewModel.SaveMode = .addNew
    @State private var overlayAsset: PHAsset? = nil
    @Namespace private var heroNS
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrollProgress: CGFloat = 0
    @State private var scrollToTopToken: Int = 0
    @State private var showSettings: Bool = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            NavigationStack {
                Group {
                    switch vm.authorizationStatus {
                    case .authorized, .limited:
                        GeometryReader { geo in
                            let cellSize = (geo.size.width - spacing*2) / 3
                            ScrollViewReader { proxy in
                            ScrollView {
                                // Sentinel for scrollToTop
                                Color.clear.frame(height: 0).id("GridTop")
                                LazyVGrid(columns: columns, spacing: spacing) {
                                    ForEach(vm.items, id: \.id) { item in
                                        GridItemView(
                                            item: item,
                                            vm: vm,
                                            cellSize: cellSize,
                                            selectionMode: selectionMode,
                                            isSelected: selected.contains(item.id),
                                            heroNS: heroNS,
                                            onTap: { overlayAsset = item.asset },
                                            onToggleSelect: {
                                                if !selectionMode { selectionMode = true }
                                                toggleSelection(id: item.id)
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 0)
                            }
                            .background(ScrollViewOffsetReader { y in
                                let p = max(0, min(1, y / 60))
                                if abs(p - scrollProgress) > 0.01 {
                                    withAnimation(.easeInOut(duration: 0.15)) { scrollProgress = p }
                                }
                            })
                            .allowsHitTesting(overlayAsset == nil)
                            .onChange(of: scrollToTopToken) { _ in
                                withAnimation(.easeInOut) { proxy.scrollTo("GridTop", anchor: .top) }
                            }
                            }
                            .ignoresSafeArea(edges: .top)
                        }
                    case .notDetermined:
                        VStack(spacing: 12) {
                            Text("需要访问相册以加载照片").foregroundStyle(.secondary)
                            Button("允许访问照片库") { vm.requestPermissionAndLoad() }
                                .buttonStyle(.borderedProminent)
                        }
                    default:
                        VStack(spacing: 12) {
                            Text("没有访问照片库权限。请到设置中开启。")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Button("重新请求权限") { vm.requestPermissionAndLoad() }
                        }
                        .padding()
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { vm.requestPermissionAndLoad(); scrollProgress = 0 }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { vm.softReloadIfNeeded() }
                }
                .onChange(of: scrollToTopToken) { _ in
                    // Smoothly scroll to very top
                    // Use NotificationCenter to bridge to ScrollViewReader if needed
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(selectionMode ? "已选 \(selected.count)" : "Heifify")
                            .font(.headline)
                            .opacity(1 - scrollProgress)
                            .onTapGesture(count: 2) {
                                // Broadcast a scroll-to-top request
                                scrollToTopToken += 1
                            }
                    }
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            ForEach(vm.albumMenu, id: \.id) { item in
                                Button {
                                    vm.currentCollection = item.collection
                                    vm.loadAssets(in: item.collection)
                                } label: {
                                    HStack {
                                        if let img = item.thumbnail {
                                            Image(uiImage: img).resizable().scaledToFill().frame(width: 22, height: 22).clipped().cornerRadius(4)
                                        } else {
                                            Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
                                        }
                                        Text("\(item.title) (\(item.count))")
                                    }
                                }
                            }
                        } label: { Image(systemName: "photo.on.rectangle.angled").opacity(1 - scrollProgress) }
                        if selectionMode {
                            Button(selected.count == vm.items.count ? "取消全选" : "全选") {
                                if selected.count == vm.items.count { selected.removeAll() } else { selected = Set(vm.items.map { $0.id }) }
                            }
                            Button("转换") { showBatchConvertSheet = true }
                            Button("完成") { selectionMode = false; selected.removeAll() }
                        }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                // Hide navigation bar once user starts scrolling up; show when at top
                .toolbar(scrollProgress > 0.12 ? .hidden : .visible, for: .navigationBar)
                .sheet(isPresented: $showBatchConvertSheet) {
                    NavigationStack {
                        ConversionOptionsView(
                            quality: $batchQuality,
                            depth: $batchDepth,
                            saveMode: $batchSaveMode,
                            showInfo: false,
                            originalSizeText: nil,
                            estimatedSizeText: nil,
                            convertButtonTitle: "开始转换 (\(selected.count))",
                            onStart: {
                                let assets = vm.items.filter { selected.contains($0.id) }.map { $0.asset }
                                vm.batchConvertToHEIF(assets: assets, quality: batchQuality, depth: batchDepth, saveMode: batchSaveMode)
                                showBatchConvertSheet = false
                            }
                        )
                        .navigationTitle("批量转换")
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .overlay {
            if let asset = overlayAsset {
                PhotoDetailView(asset: asset,
                                onClose: { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { overlayAsset = nil } },
                                matchedNamespace: heroNS,
                                matchedID: asset.localIdentifier,
                                onConverted: { vm.loadRecents() })
                .transition(.identity)
                .zIndex(10)
                .ignoresSafeArea()
            }
            if vm.isBatchConverting {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: vm.batchProgress)
                            .progressViewStyle(.circular)
                        Text(String(format: "%.0f%%", vm.batchProgress*100))
                            .font(.headline)
                        Button("取消") { vm.cancelBatchConversion() }
                            .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .transition(.opacity)
                .zIndex(20)
            }
            if let msg = vm.toastMessage {
                VStack { Spacer();
                    Text(msg)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.8))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(30)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { vm.toastMessage = nil } } }
            }
        }
    }

    private func toggleSelection(id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

#Preview {
    ContentView()
}
