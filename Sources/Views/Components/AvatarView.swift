import SwiftUI

/// Avatar shape variant. Telegram convention: 1:1 chats (DMs, secret
/// chats, people) render as circles; group chats / channels render as
/// rounded squares ("squircles") so the list scan immediately reads
/// "this is a group, not a person."
enum AvatarShape {
    case circle
    case squircle
}

struct AvatarView: View {
    let initials: String
    let colorIndex: Int
    var size: CGFloat = 42
    var photo: NSImage? = nil
    var shape: AvatarShape = .circle

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
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                resolvedShape
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
        }
        .frame(width: size, height: size)
        .clipShape(resolvedShape)
    }

    /// Resolved shape for both the placeholder fill and the outer clip.
    /// Squircle corner radius is `size * 0.27`, which matches Telegram
    /// desktop's group-avatar curvature.
    private var resolvedShape: AnyShape {
        switch shape {
        case .circle:
            return AnyShape(Circle())
        case .squircle:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        }
    }
}
