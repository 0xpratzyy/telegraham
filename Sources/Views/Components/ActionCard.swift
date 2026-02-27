import SwiftUI

/// A priority action card with colored urgency border.
struct ActionCard: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.urgency.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(item.urgency.color)

                Text(item.chatTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(item.urgency.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.urgency.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.urgency.color.opacity(0.1))
                    .clipShape(Capsule())
            }

            Text(item.senderName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(item.summary)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)

            if !item.suggestedAction.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(item.suggestedAction)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .italic()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(item.urgency.color.opacity(0.4), lineWidth: 2)
        )
    }
}
