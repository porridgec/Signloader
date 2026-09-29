import SwiftUI

struct SignOutcomeCard: View {
    @Environment(AppModel.self) private var model
    let outcome: SignOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: outcome.verification.matchesProfile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.verification.matchesProfile ? Palette.success : Palette.warning)
                Text("签名结果")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Badge(text: outcome.mode, color: .secondary)
                Button {
                    model.revealOutput()
                } label: {
                    Image(systemName: "folder").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }

            HStack(alignment: .top, spacing: 14) {
                check("代码签名", outcome.verification.hasCodeSignature)
                check("内嵌 profile", outcome.verification.hasEmbeddedProfile)
                check("application-identifier 一致", outcome.verification.matchesProfile)
            }

            HStack(spacing: 12) {
                Text("耗时 \(String(format: "%.2f", outcome.duration))s")
                Text("\(ByteFormat.string(outcome.sizeBefore)) → \(ByteFormat.string(outcome.sizeAfter))")
                if let name = outcome.verification.embeddedProfileName {
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func check(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(ok ? Palette.success : Palette.danger)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
