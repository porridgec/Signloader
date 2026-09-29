import AppKit
import SwiftUI

/// Full inspector for one provisioning profile: summary, embedded certificates,
/// provisioned devices and the raw entitlements.
struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profile: ProvisionProfile

    @State private var deviceFilter = ""
    @State private var copiedField: String?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var filteredDevices: [String] {
        let query = deviceFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return profile.devices }
        return profile.devices.filter { $0.lowercased().contains(query) }
    }

    private var connectedUDIDs: Set<String> {
        Set(model.devices.map(\.udid))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summarySection
                    certificatesSection
                    devicesSection
                    entitlementsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Palette.accent, Palette.accent.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayBundleID)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(profile.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if profile.isWildcard { Badge(text: "通配符", color: Palette.warning) }
            if let kind = model.ipa.map({ profile.matchKind(for: $0.bundleID) }), kind != .none {
                Badge(text: kind.label, color: kind == .none ? .secondary : Palette.success)
            }
            Badge(
                text: profile.expiryLabel,
                color: profile.isExpired || profile.daysRemaining < 7 ? Palette.danger
                    : (profile.daysRemaining < 30 ? Palette.warning : Palette.success)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: Sections

    private var summarySection: some View {
        section("概要", "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 5) {
                copyableRow("App ID", profile.appIdentifier)
                copyableRow("Bundle ID", profile.displayBundleID)
                copyableRow("团队", profile.teamID)
                copyableRow("UUID", profile.uuid)
                KeyValueRow(key: "创建", value: Self.dayFormatter.string(from: profile.creation), mono: false)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("到期")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    Text(Self.dayFormatter.string(from: profile.expiration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(profile.isExpired ? Palette.danger : .primary)
                    lifespanBar
                    Text(profile.expiryLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 3)

                KeyValueRow(key: "平台", value: profile.platforms.joined(separator: ", "))
                KeyValueRow(key: "Xcode 托管", value: profile.isXcodeManaged ? "是" : "否", mono: false)
                KeyValueRow(key: "重复副本", value: "\(profile.duplicateCount) 份相同内容", mono: false)
                KeyValueRow(key: "文件", value: profile.url.path)
            }
        }
    }

    /// Remaining lifetime, drawn as the coloured part reading left-to-right; the
    /// grey track is what has already elapsed. Colour is a traffic light:
    /// green while comfortable, amber inside a month, red inside a week or once
    /// expired (then the track itself goes red, since there is no bar left).
    private var lifespanBar: some View {
        let total = max(profile.expiration.timeIntervalSince(profile.creation), 1)
        let elapsed = min(max(Date().timeIntervalSince(profile.creation), 0), total)
        let remaining = max(total - elapsed, 0)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(profile.isExpired
                    ? Palette.danger.opacity(0.35)
                    : Color.primary.opacity(0.12))
                Capsule()
                    .fill(remainingColor)
                    .frame(width: proxy.size.width * (remaining / total))
            }
        }
        .frame(width: 90, height: 5)
        .help(String(
            format: "剩余 %.0f%%（共 %d 天，已过 %d 天）",
            remaining / total * 100,
            Int(total / 86_400),
            Int(elapsed / 86_400)
        ))
    }

    /// Traffic light for the remaining time. Matches the header badge.
    private var remainingColor: Color {
        if profile.isExpired || profile.daysRemaining < 7 { return Palette.danger }
        if profile.daysRemaining < 30 { return Palette.warning }
        return Palette.success
    }

    private var certificatesSection: some View {
        section("证书 (\(profile.certificates.count))", "person.text.rectangle") {
            if profile.certificates.isEmpty {
                SectionHint(text: "没有解析出证书。", systemImage: "questionmark.circle")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(profile.certificates.enumerated()), id: \.offset) { index, cert in
                        certificateRow(cert)
                        if index < profile.certificates.count - 1 {
                            Divider().padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    private func certificateRow(_ cert: ProfileCertificate) -> some View {
        let isKitCert = cert.matches(model.kit.certificate)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: cert.isExpired ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                .font(.system(size: 14))
                .foregroundStyle(cert.isExpired ? Palette.danger : (isKitCert ? Palette.success : .secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(cert.commonName.isEmpty ? "（无法解析主题）" : cert.commonName)
                    .font(.system(size: 11, weight: isKitCert ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if !cert.teamID.isEmpty {
                        Text("团队 \(cert.teamID)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(cert.validityLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(cert.isExpired ? Palette.danger : .secondary)
                    if isKitCert { Badge(text: "当前 p12", color: Palette.success) }
                    if cert.isExpired { Badge(text: "已过期", color: Palette.danger) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
    }

    private var devicesSection: some View {
        section("设备 (\(profile.devices.count))", "iphone.and.arrow.forward") {
            if profile.devices.isEmpty {
                SectionHint(
                    text: "这个 profile 不绑定设备（分发类 / App Store 类）。",
                    systemImage: "tray",
                    color: .secondary
                )
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        TextField("过滤 UDID", text: $deviceFilter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        if filteredDevices.count != profile.devices.count {
                            Text("\(filteredDevices.count)/\(profile.devices.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            copy(profile.devices.joined(separator: "\n"), label: "设备列表")
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredDevices.enumerated()), id: \.offset) { index, udid in
                                HStack(spacing: 6) {
                                    Text(udid)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    if connectedUDIDs.contains(udid) {
                                        Badge(text: "已连接", color: Palette.success)
                                    }
                                    Button {
                                        copy(udid, label: "UDID")
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("复制 UDID")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : .clear)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
                }
            }
        }
    }

    private var entitlementsSection: some View {
        section("Entitlements (\(profile.entitlements.count))", "key.horizontal") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(profile.entitlements.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let copiedField {
                Label("\(copiedField) 已复制", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.success)
                    .transition(.opacity)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([profile.url])
            } label: {
                Label("在 Finder 显示", systemImage: "folder")
            }
            Button("完成") { model.detailProfile = nil }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.2), value: copiedField)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyableRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !value.isEmpty {
                Button {
                    copy(value, label: key)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("复制\(key)")
            }
        }
    }

    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = label
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copiedField = nil
        }
    }
}
