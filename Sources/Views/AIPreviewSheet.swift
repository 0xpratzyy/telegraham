import SwiftUI

/// Shows the user exactly what data will be sent to the AI provider before sending.
struct AIPreviewSheet: View {
    let snippets: [MessageSnippet]
    let providerName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "eye.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                Text("AI Preview")
                    .font(.system(size: 16, weight: .semibold))
            }

            Text("The following data will be sent to \(providerName):")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(snippet.senderFirstName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text("in")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(snippet.chatName)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(snippet.relativeTimestamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(snippet.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("\(snippets.count) messages, ~\(totalChars) characters")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Send to \(providerName)", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var totalChars: Int {
        snippets.reduce(0) { $0 + $1.text.count }
    }
}
