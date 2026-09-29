import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Edited locally and saved explicitly: binding the field straight to
    /// `model.password` would rewrite the credential file on every keystroke.
    @State private var passwordDraft = ""

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Form {
                Section("签名工具包") {
                    pathRow(
                        title: "目录",
                        path: $model.kitPath,
                        placeholder: AppModel.defaultKitPath
                    ) {
                        Task { await model.loadKit() }
                    }
                    HStack {
                        Text("证书")
                        Spacer()
                        if let cert = model.kit.certificate {
                            let expiry = cert.notAfter.map { $0.formatted(date: .numeric, time: .omitted) } ?? "未知"
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(cert.commonName).font(.system(size: 11))
                                Text("有效期至 \(expiry) · \(cert.expiryLabel)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(cert.isValid ? Palette.success : Palette.danger)
                            }
                        } else {
                            Text("未找到").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("p12 密码")
                        Spacer()
                        if model.passwordIsFromEnvironment {
                            Label("由 \(PasswordStore.environmentVariable) 提供", systemImage: "lock.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            SecureField("密码", text: $passwordDraft)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .frame(width: 150)
                                .onSubmit(savePassword)
                            Button("保存", action: savePassword)
                                .controlSize(.small)
                                .disabled(passwordDraft == model.password)
                        }
                    }
                    Text("密码只存本机 Keychain（仅本设备、解锁时可读），不进仓库。命令行可用 \(PasswordStore.environmentVariable) 环境变量覆盖。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if model.kit.certificateURL != nil {
                        Text("文件：\((model.kit.certificateURL?.path as NSString?)?.abbreviatingWithTildeInPath ?? "")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("产物") {
                    pathRow(
                        title: "输出目录",
                        path: $model.outputDirectory,
                        placeholder: AppModel.defaultOutputDirectory
                    ) {}
                }

                Section("工具链") {
                    let missing = model.missingTools
                    if missing.isEmpty {
                        Label("zsign / idevice_id / ideviceinstaller / libimobiledevice 都在", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.success)
                            .font(.system(size: 11))
                    } else {
                        Label("缺少：\(missing.joined(separator: ", "))（brew install zsign libimobiledevice）", systemImage: "xmark.circle.fill")
                            .foregroundStyle(Palette.danger)
                            .font(.system(size: 11))
                    }
                    HStack {
                        Button("打开工具包目录") { model.revealKitInFinder() }
                        Spacer()
                        Button("重新扫描") { Task { await model.loadKit() } }
                    }
                }

                Section("快捷键") {
                    KeyValueRow(key: "⌘O", value: "选择 IPA", mono: false)
                    KeyValueRow(key: "⌘R", value: "重新扫描工具包", mono: false)
                    KeyValueRow(key: "⌘D", value: "刷新设备", mono: false)
                    KeyValueRow(key: "S", value: "签名", mono: false)
                    KeyValueRow(key: "I", value: "安装到设备", mono: false)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") {
                    savePassword()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
        .onAppear { passwordDraft = model.password }
    }

    private func savePassword() {
        guard passwordDraft != model.password else { return }
        model.password = passwordDraft
    }

    private func pathRow(
        title: String,
        path: Binding<String>,
        placeholder: String,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: path)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(onChange)
        }
    }
}
