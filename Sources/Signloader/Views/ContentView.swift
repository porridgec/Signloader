import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var showIPAFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                leftColumn
                    .frame(minWidth: 380, idealWidth: 430, maxWidth: 560)
                rightColumn
                    .frame(minWidth: 420)
            }
            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
            Task { await model.loadIPA(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Palette.accent.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environment(model) }
        .sheet(item: Binding(
            get: { model.detailProfile },
            set: { model.detailProfile = $0 }
        )) { profile in
            ProfileDetailView(profile: profile)
                .environment(model)
        }
        .fileImporter(
            isPresented: $showIPAFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.loadIPA(url) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .signloaderPickIPA)) { _ in
            showIPAFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .signloaderLoadIPA)) { note in
            guard let url = note.object as? URL else { return }
            Task { await model.loadIPA(url) }
        }
        .alert(
            "出错了",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Palette.accent, Palette.accent.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Image(systemName: "signature")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Signloader")
                    .font(.system(size: 14, weight: .bold))
                Text(kitSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 22)

            devicePicker

            Spacer(minLength: 8)

            if !model.missingTools.isEmpty {
                Badge(text: "缺 \(model.missingTools.joined(separator: ", "))", color: Palette.danger)
            }

            ToolbarIconButton(systemImage: "arrow.clockwise", help: "重新扫描签名工具包") {
                Task { await model.loadKit() }
            }
            .disabled(model.isBusy)

            ToolbarIconButton(systemImage: "gearshape", help: "设置") { showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var kitSubtitle: String {
        var parts: [String] = []
        if let cert = model.kit.certificate {
            parts.append("证书 \(cert.expiryLabel)")
        }
        if let team = model.kit.teamIDs.first {
            parts.append("团队 \(team)")
        }
        parts.append("\(model.kit.profiles.count) 个 profile")
        if model.kit.scannedFileCount > model.kit.profiles.count {
            parts.append("(\(model.kit.scannedFileCount) 个文件去重)")
        }
        return parts.joined(separator: " · ")
    }

    private var devicePicker: some View {
        HStack(spacing: 6) {
            // Colour carries reachability (green = answered at scan time,
            // grey = discovered but unreachable); shape carries the transport.
            Image(systemName: selectedTransportSymbol)
                .font(.system(size: 11))
                .foregroundStyle(transportIndicatorColor)
                .help(selectedTransportHint)
            Picker("", selection: Binding(
                get: { model.selectedDevice?.udid ?? "" },
                set: { udid in
                    model.selectedDevice = model.devices.first { $0.udid == udid }
                    Task { await model.loadInstalledApps() }
                }
            )) {
                Text("无设备").tag("")
                ForEach(model.devices) { device in
                    Text(rowLabel(for: device)).tag(device.udid)
                }
            }
            .labelsHidden()
            .frame(minWidth: 180)

            Button {
                Task { await model.loadDevices() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("刷新设备列表（USB + Wi-Fi）")
            .disabled(model.isBusy)
        }
    }

    private var selectedTransportSymbol: String {
        switch model.selectedDevice {
        case .none: return "iphone"
        case .some(let device):
            if !device.reachable { return "exclamationmark.wifi" }
            return device.transport.symbol
        }
    }

    /// Green = the device answered us at scan time; grey = discovered but not
    /// reachable. Never amber — that would read as a warning, and reachability
    /// is binary here, not degraded.
    private var transportIndicatorColor: Color {
        guard let device = model.selectedDevice else { return Palette.subtle }
        return device.reachable ? Palette.success : Palette.subtle
    }

    private var selectedTransportHint: String {
        switch model.selectedDevice {
        case .none:
            return "未选择设备"
        case .some(let device):
            let transport = device.transport == .network
                ? "Wi-Fi 连接：无需线缆，但传输大 IPA 明显慢于 USB"
                : "USB 连接"
            return device.reachable ? transport : "\(transport) · 最近一次扫描时不可达"
        }
    }

    private func rowLabel(for device: Device) -> String {
        device.reachable
            ? "\(device.displayName) · \(device.transport.label)"
            : "\(device.displayName) · \(device.transport.label)（不可达）"
    }

    // MARK: Left column

    private var leftColumn: some View {
        ScrollView {
            VStack(spacing: 12) {
                IPACard(onChoose: { showIPAFileImporter = true })
                if let ipa = model.ipa {
                    SigningOptionsCard(ipa: ipa)
                }
                ProfileCard()
                InstalledAppsCard()
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(spacing: 0) {
            LogConsoleView()
            if let outcome = model.lastOutcome {
                Divider()
                SignOutcomeCard(outcome: outcome)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            StatusIndicator()

            Spacer(minLength: 12)

            if model.isBundleIDInstalled {
                Button {
                    Task { await model.uninstallCurrent() }
                } label: {
                    Label("卸载 \(model.ipa?.displayName ?? "当前 App")", systemImage: "trash")
                }
                .controlSize(.large)
                .disabled(model.isBusy)
                .help("覆盖安装报 MismatchedApplicationIdentifierEntitlement 时，先卸载再装")
            }

            if let output = model.outputURL {
                Button {
                    model.revealOutput()
                } label: {
                    Label("打开产物", systemImage: "folder")
                }
                .controlSize(.large)
                .help(output.path)
            }

            Button {
                Task { await model.install() }
            } label: {
                Label("安装到设备", systemImage: "arrow.down.app")
            }
            .controlSize(.large)
            .disabled(!model.canInstall)

            Button {
                Task { await model.sign() }
            } label: {
                Label(model.busy == .signing ? "签名中…" : "签名", systemImage: "signature")
                    .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSign)
            .keyboardShortcut("s", modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Status

private struct StatusIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 260, alignment: .leading)
    }

    private var statusSymbol: String {
        if model.ipa == nil { return "square.dashed" }
        if model.selectedProfile == nil { return "exclamationmark.triangle.fill" }
        if model.lastOutcome == nil { return "circle.dashed" }
        return model.lastOutcome!.verification.matchesProfile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if model.ipa == nil { return .secondary }
        if model.selectedProfile == nil { return Palette.warning }
        guard let outcome = model.lastOutcome else { return .secondary }
        return outcome.verification.matchesProfile ? Palette.success : Palette.warning
    }

    private var statusText: String {
        if model.isBusy { return model.busy.label }
        if let problem = model.errorMessage { return problem }
        if model.ipa == nil { return "拖一个 .ipa 进来，或点「选择 IPA」" }
        if model.selectedProfile == nil { return "没有可用的描述文件" }
        if let outcome = model.lastOutcome {
            let ok = outcome.verification.matchesProfile
            return ok
                ? "已签名：\(outcome.outputURL.lastPathComponent)"
                : "已签名，但内嵌 profile 与所选不一致"
        }
        return "准备就绪：\(model.ipa!.displayName) + \(model.selectedProfile?.displayBundleID ?? "")"
    }
}

// MARK: - Toolbar button

struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
