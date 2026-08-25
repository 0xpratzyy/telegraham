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
                resolvedShape
                    .fill(Self.colors[colorIndex % Self.colors.count].opacity(0.22))

                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: photoContentMode)
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

                Text(displayInitials)
                    .font(.system(size: initialsFontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(resolvedShape)
    }

    /// At evidence-row scale an aspect-fill crop can remove most of an
    /// off-centre face. Preserve the whole profile image at 16pt and below;
    /// larger list/detail avatars keep the familiar edge-to-edge fill.
    private var photoContentMode: ContentMode {
        size <= 16 ? .fit : .fill
    }

    /// Two initials become illegible inside the compact 14pt evidence avatar.
    /// Use one stable initial there and retain the normal two-letter treatment
    /// everywhere else.
    private var displayInitials: String {
        size <= 16 ? String(initials.prefix(1)) : initials
    }

    private var initialsFontSize: CGFloat {
        size * (size <= 16 ? 0.46 : 0.38)
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
