import SwiftUI

struct StatusDot: View {
    let isConnected: Bool

    var body: some View {
        Circle()
            .fill(isConnected ? Color.Pidgy.success : Color.Pidgy.danger)
            .frame(width: 8, height: 8)
            .shadow(color: (isConnected ? Color.Pidgy.success : Color.Pidgy.danger).opacity(0.35), radius: 3)
    }
}
