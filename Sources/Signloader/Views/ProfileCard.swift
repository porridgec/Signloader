import SwiftUI

struct ProfileCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(
            title: "描述文件 (\(model.kit.profiles.count))",
            systemImage: "checkmark.seal",
            accessory: AnyView(
                HStack(spacing: 4) {
                    if model.kit.profiles.isEmpty {
                        Text(model.busy == .scanningKit ? "扫描中…" : "工具包里没有 profile")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("过滤", text: Binding(
                            get: { model.profileFilter },
                            set: { model.profileFilter = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 100)
                    }
                }
            )
        ) {
            if model.kit.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHint(
                        text: "在设置里指向 _signing-kit 目录，或点下面的按钮从手机重新导出。",
                        systemImage: "tray",
                        color: .secondary
                    )
                    HStack {
                        Button("打开工具包") { model.revealKit() }
                        Button("从设备导出") { Task { await model.refreshProfilesFromDevice() } }
                            .disabled(model.selectedDevice == nil || model.isBusy)
                    }
                    .controlSize(.small)
                }
                .padding(12)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.filteredProfiles.enumerated()), id: \.element.id) { index, profile in
                                row(profile)
                                if index < model.filteredProfiles.count - 1 {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)

                    Divider()
                    footer
                }
            }
        }
    }

    private func row(_ profile: ProvisionProfile) -> some View {
        let isSelected = model.selectedProfile?.id == profile.id
        let kind = model.ipa.map { profile.matchKind(for: $0.bundleID) } ?? .none

        return Button {
            model.selectedProfile = profile
            model.lastProfileSelectionWasAutomatic = false
            model.log("选择 profile：\(profile.appIdentifier)", .info)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Palette.accent : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(profile.displayBundleID)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if profile.isWildcard {
                            Badge(text: "*", color: .secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(profile.expiryLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(expiryColor(profile))
                        if profile.duplicateCount > 1 {
                            Text("×\(profile.duplicateCount)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .help("工具包里有 \(profile.duplicateCount) 份相同内容的副本")
                        }
                        if model.ipa != nil {
                            Badge(text: kind.label, color: kindColor(kind))
                        }
                    }
                }

                Spacer(minLength: 4)

                if profile.isWildcard {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("通配符 profile：任何 bundle id 都能签，但只能新装")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Palette.accent.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
    }

    private func expiryColor(_ profile: ProvisionProfile) -> Color {
        if profile.isExpired { return Palette.danger }
        if profile.daysRemaining < 30 { return Palette.warning }
        return .secondary
    }

    private func kindColor(_ kind: ProvisionProfile.MatchKind) -> Color {
        switch kind {
        case .teamSuffixed: return Palette.success
        case .exact: return Palette.accent
        case .wildcard: return Palette.warning
        case .none: return .secondary
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: model.lastProfileSelectionWasAutomatic ? "wand.and.stars" : "hand.tap")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("自动匹配") {
                model.reselectProfile(automatic: true)
            }
            .controlSize(.small)
            .disabled(model.ipa == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var footerText: String {
        guard let profile = model.selectedProfile else { return "未选择" }
        guard let ipa = model.ipa else { return "已选 \(profile.displayBundleID)，载入 IPA 后自动匹配" }
        switch profile.matchKind(for: ipa.bundleID) {
        case .teamSuffixed:
            return "后缀 profile 与设备上已装的旧版同源，覆盖安装可保留应用数据"
        case .exact:
            return "bundle id 完全一致"
        case .wildcard:
            return "通配符：可新装；覆盖已存在的旧版会报 entitlement 不匹配"
        case .none:
            return "此 profile 不覆盖 \(ipa.bundleID)，签名后无法安装"
        }
    }
}
