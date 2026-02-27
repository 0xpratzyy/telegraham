import SwiftUI

struct StatusDot: View {
    let isConnected: Bool

    var body: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: isConnected ? .green.opacity(0.5) : .red.opacity(0.5), radius: 3)
    }
}
