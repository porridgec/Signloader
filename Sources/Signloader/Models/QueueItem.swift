import Foundation

/// One IPA in the batch queue. Each item is processed on its own: parse →
/// auto-match profile → sign → install. State is per-item so one failure never
/// stops the rest.
struct QueueItem: Identifiable, Hashable {
    enum State: String, CaseIterable {
        case pending    = "等待"
        case working    = "处理中"
        case done       = "完成"
        case failed     = "失败"
        case cancelled  = "已取消"

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .pending, .working: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    var state: State = .pending
    /// Current stage or the error that failed this item.
    var note: String = ""

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}
