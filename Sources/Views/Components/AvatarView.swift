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
    /// Remote avatar (e.g. a Slack profile image URL) loaded when no local
    /// `photo` is available. Falls back to the initials placeholder while
    /// loading or on failure.
    var avatarURL: String? = nil
    var shape: AvatarShape = .circle
    /// When set to a non-Telegram source, overlays a small platform glyph
    /// (e.g. the Slack logo) in the corner so multi-source lists read at a
    /// glance. Telegram is the default and stays unbadged.
    var sourceKind: MessageSourceKind? = nil

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
            } else if let avatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(resolvedShape)
        .overlay(alignment: .bottomTrailing) {
            if let sourceKind, sourceKind != .telegram {
                Image(sourceKind.glyphAssetName)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.34, height: size * 0.34)
                    .padding(size * 0.05)
                    .background(Circle().fill(Color.Pidgy.bg1))
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
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
