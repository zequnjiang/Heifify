import SwiftUI

struct ConversionOptionsView: View {
    @Binding var quality: Double
    @Binding var depth: ImageBitDepth
    @Binding var saveMode: PhotoDetailViewModel.SaveMode
    var showInfo: Bool
    var originalSizeText: String?
    var estimatedSizeText: String?
    var convertButtonTitle: String
    var onStart: () -> Void

    var body: some View {
        Form {
            if showInfo {
                Section("信息") {
                    HStack { Text("原始大小"); Spacer(); Text(originalSizeText ?? "—") }
                    HStack { Text("HEIF 估算"); Spacer(); Text(estimatedSizeText ?? "—") }
                }
            }
            Section("保存") {
                Picker("保存方式", selection: $saveMode) {
                    Text("保存到相册").tag(PhotoDetailViewModel.SaveMode.addNew)
                    Text("覆盖当前").tag(PhotoDetailViewModel.SaveMode.overwrite)
                }
                .pickerStyle(.segmented)
                Text("覆盖当前会以非破坏性编辑方式应用，原片可在相册中还原。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("参数") {
                HStack(spacing: 12) {
                    Text("压缩比")
                    Slider(value: $quality, in: 0.3...1.0, step: 0.05)
                    Text(String(format: "%.2f", quality)).monospacedDigit()
                }
                HStack {
                    Text("色深")
                    Picker("色深", selection: $depth) {
                        Text("8-bit").tag(ImageBitDepth.eightBit)
                        Text("10-bit(若支持)").tag(ImageBitDepth.tenBit)
                    }.pickerStyle(.segmented)
                }
            }
            Section {
                HStack { Spacer()
                    Button(convertButtonTitle) { onStart() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Spacer() }
            }
        }
    }
}

