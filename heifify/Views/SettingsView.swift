import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // AppStorage for a few preferences (can be wired into flows later)
    @AppStorage("defaultQuality") private var defaultQuality: Double = 0.8
    @AppStorage("defaultSaveMode") private var defaultSaveModeRaw: Int = 0 // 0 add, 1 overwrite
    @AppStorage("wifiOnlyDownload") private var wifiOnlyDownload: Bool = false
    @AppStorage("showSizeBadges") private var showSizeBadges: Bool = true

    var defaultSaveMode: PhotoDetailViewModel.SaveMode {
        get { defaultSaveModeRaw == 1 ? .overwrite : .addNew }
        set { defaultSaveModeRaw = (newValue == .overwrite ? 1 : 0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        if let icon = AppInfo.primaryIcon() {
                            Image(uiImage: icon).resizable().scaledToFit().frame(width: 60, height: 60).cornerRadius(12)
                        } else {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        }
                        VStack(alignment: .leading) {
                            Text(AppInfo.displayName).font(.headline)
                            Text("版本 \(AppInfo.marketingVersion) (\(AppInfo.buildVersion))")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        Spacer()
                    }.padding(.vertical, 4)
                }

                Section("转换默认选项") {
                    HStack { Text("默认压缩比"); Slider(value: $defaultQuality, in: 0.3...1.0, step: 0.05); Text(String(format: "%.2f", defaultQuality)).monospacedDigit() }
                    Picker("保存方式", selection: Binding(get: { defaultSaveMode }, set: { newVal in defaultSaveModeRaw = (newVal == .overwrite ? 1 : 0) })) {
                        Text("保存到相册").tag(PhotoDetailViewModel.SaveMode.addNew)
                        Text("覆盖当前").tag(PhotoDetailViewModel.SaveMode.overwrite)
                    }.pickerStyle(.segmented)
                    Text("此设置作为默认值，具体转换面板仍可临时更改。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("浏览与下载") {
                    Toggle("仅在 Wi‑Fi 下从 iCloud 下载原图", isOn: $wifiOnlyDownload)
                    Toggle("在网格中显示大小徽标", isOn: $showSizeBadges)
                }

                Section("关于") {
                    Link("项目主页 (GitHub)", destination: URL(string: "https://github.com/zequnjiang/Heifify")!)
                    Text("版权所有 © \(Calendar.current.component(.year, from: Date())) Heifify")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

enum AppInfo {
    static var displayName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Heifify") }
    static var marketingVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var buildVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

    static func primaryIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last) ?? UIImage(named: "AppIcon")
    }
}
