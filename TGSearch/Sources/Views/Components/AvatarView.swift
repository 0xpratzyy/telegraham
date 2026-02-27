import SwiftUI

struct AvatarView: View {
    let initials: String
    let colorIndex: Int
    var size: CGFloat = 42

    private static let colors: [Color] = [
        Color(red: 0.39, green: 0.40, blue: 0.95), // Indigo
        Color(red: 0.85, green: 0.36, blue: 0.36), // Red
        Color(red: 0.13, green: 0.77, blue: 0.47), // Green
        Color(red: 0.96, green: 0.62, blue: 0.07), // Orange
        Color(red: 0.55, green: 0.36, blue: 0.95), // Purple
        Color(red: 0.07, green: 0.75, blue: 0.82), // Teal
        Color(red: 0.95, green: 0.41, blue: 0.66), // Pink
        Color(red: 0.38, green: 0.65, blue: 0.95), // Blue
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
