import SwiftUI

/// Reveals text character-by-character with a typing animation.
struct TypingTextView: View {
    let fullText: String
    var speed: Double = 40 // characters per second

    @State private var revealedCount = 0
    @State private var isComplete = false

    var body: some View {
        Text(String(fullText.prefix(revealedCount)))
            .onAppear { startTyping() }
            .onChange(of: fullText) {
                revealedCount = 0
                isComplete = false
                startTyping()
            }
    }

    private func startTyping() {
        guard !isComplete else { return }
        let totalChars = fullText.count
        guard totalChars > 0 else { return }

        Task { @MainActor in
            let interval = 1.0 / speed
            while revealedCount < totalChars {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled else { break }
                revealedCount += 1
            }
            isComplete = true
        }
    }
}
