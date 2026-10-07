import SwiftUI

struct SigningOptionsCard: View {
    @Environment(AppModel.self) private var model
    let ipa: IPAInfo

    @FocusState private var bundleIDFieldFocused: Bool
    @FocusState private var appNameFieldFocused: Bool

    var body: some View {
        // $model 需要局部 @Bindable：手写 Binding(get:set:) 不参与观察追踪，
        // 用它驱动 sheet/输入框会出现「赋值了但界面不更新」的问题
        @Bindable var model = model

        return Card(title: "签名选项", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: binding(\.safeMode)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("大 App 安全模式")
                        Text("unzip → zsign -f → ditto，绕开 zsign 打包超大 IPA 时的异常")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 8) {
                    Text("压缩等级")
                        .font(.system(size: 11))
                    Slider(
                        value: Binding(
                            get: { Double(model.options.zipLevel) },
                            set: { model.options.zipLevel = Int($0.rounded()) }
                        ),
                        in: 0...9,
                        step: 1
                    )
                    Text(model.options.zipLevel == 0 ? "0 (store)" : "\(model.options.zipLevel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                }

                Divider()

                TextField("改 Bundle ID（清空 = 保持原值）", text: $model.bundleIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($bundleIDFieldFocused)
                    .onChange(of: bundleIDFieldFocused) { _, focused in
                        if focused { model.prefillBundleIDDraft() }
                    }

                TextField("改 App 显示名（清空 = 保持原值）", text: $model.appNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($appNameFieldFocused)
                    .onChange(of: appNameFieldFocused) { _, focused in
                        if focused { model.prefillAppNameDraft() }
                    }

                Toggle(isOn: binding(\.removeAppExtensions)) {
                    Text("移除 App 扩展（PlugIns）").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(ipa.appExtensionNames.isEmpty)

                Toggle(isOn: binding(\.removeWatchApp)) {
                    Text("移除 Watch App").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(ipa.watchAppName == nil)

                Toggle(isOn: binding(\.stripEmbeddedProfile)) {
                    Text("移除内嵌 profile（zsign -R，签完就删，装不上）").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .tint(Palette.danger)

                Divider()

                Toggle(isOn: binding(\.installAfterSigning)) {
                    Text("签名后自动安装").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: binding(\.uninstallBeforeInstall)) {
                    Text("安装前先卸载旧版").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(!model.options.installAfterSigning || model.selectedDevice == nil)

                // 只有「真的改成了别的值」才算改了 bundle id；预填的原值不算
                if model.bundleIDDraft.isEmpty || model.bundleIDDraft == ipa.bundleID {
                    SectionHint(
                        text: "想覆盖安装就保持 bundle id 不变，并选带团队后缀的 profile；改了 bundle id 就得先卸载，应用数据也会丢。",
                        systemImage: "lightbulb",
                        color: .secondary
                    )
                } else {
                    SectionHint(
                        text: "改了 bundle id = 全新 App：必须先卸载旧版，且拿不到原来的应用数据。",
                        systemImage: "exclamationmark.triangle",
                        color: Palette.warning
                    )
                }
            }
            .padding(12)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SigningOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.options[keyPath: keyPath] },
            set: { model.options[keyPath: keyPath] = $0 }
        )
    }

}
