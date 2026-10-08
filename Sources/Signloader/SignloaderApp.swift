import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point: hands off to the CLI when arguments are present, otherwise
/// starts the SwiftUI app.
@main
enum SignloaderMain {
    static func main() {
        // Arguments present → CLI mode. Run it on a detached task and block the
        // main thread; a plain `Task {}` would inherit the main actor and
        // deadlock against the semaphore.
        if CommandLine.arguments.count > 1 {
            let arguments = CommandLine.arguments
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task.detached {
                    let code = await CLI.run(arguments)
                    exit(Int32(code))
                }
            }
            semaphore.wait()
            exit(0)
        }
        SignloaderApp.main()
    }
}

struct SignloaderApp: App {
    @State private var model = AppModel()
    @State private var showingSettings = false

    var body: some Scene {
        // A single long-lived window: re-opening the app brings this one back
        // instead of stacking new ones.
        Window("Signloader", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1_040, minHeight: 660)
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                        .environment(model)
                }
                .task {
                    await model.loadKit()
                    await model.loadDevices()
                }
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "ipa" {
                        Task { await model.loadIPA(url) }
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("选择 IPA…") { NotificationCenter.default.post(name: .signloaderPickIPA, object: nil) }
                    .keyboardShortcut("o")
                Button("从主目录选…") { pickIPAFromWorkspace() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("批量选择 IPA 入队…") {
                    NotificationCenter.default.post(name: .signloaderBatchPickIPA, object: nil)
                }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("重新扫描签名工具包") { Task { await model.loadKit() } }
                    .keyboardShortcut("r")
                Button("刷新设备") { Task { await model.loadDevices() } }
                    .keyboardShortcut("d")
            }
            CommandGroup(after: .toolbar) {
                Button("设置…") { showingSettings = true }
                    .keyboardShortcut(",")
            }
            CommandMenu("签名") {
                Button("签名") { Task { await model.sign() } }
                    .keyboardShortcut("s")
                    .disabled(!model.canSign)
                Button("安装到设备") { Task { await model.install() } }
                    .keyboardShortcut("i")
                    .disabled(!model.canInstall)
                Divider()
                Button("打开产物所在文件夹") { model.revealOutput() }
                    .disabled(model.outputURL == nil)
            }
        }
    }
}

extension Notification.Name {
    static let signloaderPickIPA = Notification.Name("Signloader.pickIPA")
    static let signloaderLoadIPA = Notification.Name("Signloader.loadIPA")
    static let signloaderBatchPickIPA = Notification.Name("Signloader.batchPickIPA")
}

/// `⌘⇧O` opens the panel in the user's home directory as a convenient default.
func pickIPAFromWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    panel.message = "选一个 .ipa"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    NotificationCenter.default.post(name: .signloaderLoadIPA, object: url)
}
