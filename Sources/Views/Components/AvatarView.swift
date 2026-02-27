import SwiftUI

struct AvatarView: View {
    let initials: String
    let colorIndex: Int
    var size: CGFloat = 42

    private static let colors: [Color] = [
        .indigo,
        .red,
        .green,
        .orange,
        .purple,
        .teal,
        .pink,
        .blue,
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Self.colors[colorIndex % Self.colors.count],
                            Self.colors[colorIndex % Self.colors.count].opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
