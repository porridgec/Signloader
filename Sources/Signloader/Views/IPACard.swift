import SwiftUI

struct IPACard: View {
    @Environment(AppModel.self) private var model
    var onChoose: () -> Void

    var body: some View {
        Card(
            title: "IPA",
            systemImage: "shippingbox",
            accessory: AnyView(
                HStack(spacing: 4) {
                    if model.ipa != nil {
                        ToolbarIconButton(systemImage: "arrow.up.forward.app", help: "在 Finder 中显示源 IPA") {
                            model.revealIPA()
                        }
                    }
                    Button("选择…", action: onChoose)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            )
        ) {
            if let ipa = model.ipa {
                content(ipa)
            } else {
                empty
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.7))
            Text("把 .ipa 拖进窗口")
                .font(.system(size: 12, weight: .medium))
            Text("或点右上角「选择…」")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
    }

    private func content(_ ipa: IPAInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                icon(for: ipa)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ipa.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(ipa.versionLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Badge(text: ByteFormat.string(ipa.fileSize), color: .secondary)
                        if ipa.recommendsSafeMode {
                            Badge(text: "建议安全模式", color: Palette.warning)
                        }
                        if !model.isBundleIDInstalled && model.installedApps.isEmpty == false {
                            Badge(text: "未安装", color: Palette.success)
                        } else if model.isBundleIDInstalled {
                            Badge(text: "已安装", color: Palette.accent)
                        }
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(key: "Bundle ID", value: ipa.bundleID)
                KeyValueRow(key: "可执行文件", value: ipa.executable)
                if !ipa.minimumOS.isEmpty {
                    KeyValueRow(key: "最低系统", value: "iOS " + ipa.minimumOS)
                }
                KeyValueRow(key: "文件条目", value: "\(ipa.entryCount)")
                if !ipa.appExtensionNames.isEmpty {
                    KeyValueRow(key: "扩展", value: ipa.extensionSummary)
                }
                if let watch = ipa.watchAppName {
                    KeyValueRow(key: "Watch", value: watch)
                }
            }

            if let output = model.outputURL {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text((output.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    Button {
                        model.copyOutputPath()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("复制产物路径")
                }
            }
        }
        .padding(12)
    }

    private func icon(for ipa: IPAInfo) -> some View {
        Group {
            if let image = ipa.icon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.secondary.opacity(0.28), Color.secondary.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Image(systemName: "app.dashed")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }
}
