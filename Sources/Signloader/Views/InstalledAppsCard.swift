import SwiftUI

struct InstalledAppsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(
            title: "设备上的 App (\(model.installedApps.count))",
            systemImage: "iphone.gen3",
            accessory: AnyView(
                HStack(spacing: 4) {
                    if model.selectedDevice != nil {
                        TextField("搜索", text: Binding(
                            get: { model.appFilter },
                            set: { model.appFilter = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 90)
                    }
                }
            )
        ) {
            if model.selectedDevice == nil {
                SectionHint(
                    text: "USB 连上 iPhone 后这里会列出已安装的 App，用来判断是否需要先卸载。",
                    systemImage: "cable.connector",
                    color: .secondary
                )
                .padding(12)
            } else if model.isBusy && model.busy == .scanningApps {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("读取中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if model.filteredApps.isEmpty {
                SectionHint(
                    text: model.appFilter.isEmpty ? "没有读到已安装的 App。" : "没有匹配「\(model.appFilter)」的 App。",
                    systemImage: "magnifyingglass",
                    color: .secondary
                )
                .padding(12)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.filteredApps.enumerated()), id: \.element.id) { index, app in
                                row(app)
                                if index < model.filteredApps.count - 1 {
                                    Divider().padding(.leading, 30)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)

                    Divider()
                    Button {
                        Task { await model.loadInstalledApps() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        let isCurrent = app.bundleID == model.ipa?.bundleID
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "app.badge.checkmark" : "app")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? Palette.success : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    if isCurrent { Badge(text: "当前 IPA", color: Palette.success) }
                }
                Text(app.bundleID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(app.versionLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                Task { await model.uninstall(app) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("卸载 \(app.name)")
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
