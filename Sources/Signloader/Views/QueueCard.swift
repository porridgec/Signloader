import SwiftUI

/// Batch queue: drop or pick several IPAs, then process them one by one
/// (parse → auto-match profile → sign → install). Only shown when the queue
/// has content.
struct QueueCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(
            title: "队列 (\(model.queue.count))",
            systemImage: "list.number",
            accessory: AnyView(
                Text(model.queueSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            )
        ) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < model.queue.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)

                Divider()

                HStack(spacing: 8) {
                    if model.queueRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Button("停止") { model.stopQueue() }
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await model.runQueue() }
                        } label: {
                            Label(
                                model.selectedDevice == nil ? "全部签名" : "全部签名并安装",
                                systemImage: model.selectedDevice == nil ? "signature" : "arrow.down.app"
                            )
                        }
                        .controlSize(.small)
                        .disabled(!model.queue.contains { !$0.state.isFinished })
                    }

                    Spacer(minLength: 4)

                    Button("清空已完成") { model.clearQueue(finishedOnly: true) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .disabled(!model.queue.contains { $0.state.isFinished })

                    Button("清空") { model.clearQueue(finishedOnly: false) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .disabled(model.queue.isEmpty)

                    Button {
                        Task { await model.refreshDevicesForQueueHint() }
                    } label: {
                        Text(model.selectedDevice == nil ? "未选设备（仅签名）" : "目标：\(model.selectedDevice!.displayName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(model.selectedDevice == nil
                        ? "在顶部选择设备后，队列会签名并安装"
                        : "队列将安装到 \(model.selectedDevice!.displayName)（\(model.selectedDevice!.transport.label)）")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
    }

    private func row(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: item.state))
                .font(.system(size: 11))
                .foregroundStyle(color(for: item.state))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: item.state == .working ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(item.state == .failed ? Palette.danger : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if item.state == .working {
                Text("处理中")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.accent)
            }

            Button {
                model.removeFromQueue(item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(item.state == .working)
            .help(item.state == .working ? "处理中——先停止队列" : "移除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            // 点一行 = 把它载入主详情查看（队列空闲时）
            guard !model.queueRunning else { return }
            Task { await model.loadIPA(item.url) }
        }
    }

    private func symbol(for state: QueueItem.State) -> String {
        switch state {
        case .pending: return "clock"
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private func color(for state: QueueItem.State) -> Color {
        switch state {
        case .pending: return .secondary
        case .working: return Palette.accent
        case .done: return Palette.success
        case .failed: return Palette.danger
        case .cancelled: return .secondary
        }
    }
}
