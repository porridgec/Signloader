import SwiftUI

struct LogConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var follow = true

    private var visible: [LogEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.log }
        return model.log.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            console
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("日志", systemImage: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            TextField("过滤日志", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)

            Toggle(isOn: $follow) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10))
            }
            .toggleStyle(.button)
            .help("自动滚动到最新")

            Spacer(minLength: 0)

            Text("\(model.log.count) 行")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.log.map(\.text).joined(separator: "\n"), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(model.log.isEmpty)
            .help("复制全部日志")

            Button {
                model.log.removeAll()
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(model.log.isEmpty)
            .help("清空")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { entry in
                        row(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.log.count) {
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .overlay {
            if model.log.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("zsign / ideviceinstaller 的输出会显示在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(Self.clock.string(from: entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: entry.level.symbol)
                .font(.system(size: 9))
                .foregroundStyle(color(for: entry.level))
                .frame(width: 11)
            Text(entry.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(entry.level == .command ? Palette.accent : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .command: return Palette.accent
        case .info: return .secondary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
