import SwiftUI

// MARK: - Palette

enum Palette {
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.98)
    static let success = Color(red: 0.30, green: 0.76, blue: 0.47)
    static let warning = Color(red: 0.95, green: 0.66, blue: 0.20)
    static let danger = Color(red: 0.91, green: 0.35, blue: 0.35)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color.primary.opacity(0.55)
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(title: String, systemImage: String, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Spacer(minLength: 8)
                if let accessory { accessory }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.35))

            Divider()
            content
        }
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - Small building blocks

struct Badge: View {
    let text: String
    var color: Color = Palette.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.16))
            )
            .foregroundStyle(filled ? .white : color)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = true
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct SectionHint: View {
    let text: String
    var systemImage: String = "info.circle"
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// Selectable IPA drop target used by the header card.
    func ipaDropTarget(isTargeted: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(isTargeted ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}
