import SwiftUI

enum DashboardPreferenceStatus: Equatable {
    case success(String)
    case error(String)

    var text: String {
        switch self {
        case .success(let text), .error(let text):
            return text
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return PidgyDashboardTheme.green
        case .error:
            return PidgyDashboardTheme.red
        }
    }
}

struct DashboardPreferenceStatusItem: Identifiable {
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    let tint: Color

    var id: String { title }
}

struct DashboardPreferenceControlMosaic: View {
    let page: DashboardPreferencePage
    let primary: DashboardPreferenceStatusItem
    let items: [DashboardPreferenceStatusItem]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashboardPreferenceFocusCard(page: page, item: primary)
                .frame(minWidth: 360, maxWidth: .infinity)

            VStack(spacing: 10) {
                ForEach(items.filter { $0.id != primary.id }.prefix(3)) { item in
                    DashboardPreferenceMiniStatusCard(item: item)
                }
            }
            .frame(width: 310)
        }
    }
}

private struct DashboardPreferenceFocusCard: View {
    let page: DashboardPreferencePage
    let item: DashboardPreferenceStatusItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.brand)
                    .frame(width: 42, height: 42)
                    .background(PidgyDashboardTheme.brand.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(page.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text(page.subtitle)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                DashboardLiveStatusDot(tint: item.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.uppercased())
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .tracking(0.7)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.value)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text(item.caption)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(PidgyDashboardTheme.deep)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .padding(16)
        .frame(minHeight: 156, alignment: .topLeading)
        .background(PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardPreferenceMiniStatusCard: View {
    let item: DashboardPreferenceStatusItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.6)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Text(item.value)
                    .font(PidgyDashboardTheme.rowEmphasisFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(item.caption)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minHeight: 45)
        .background(PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardLiveStatusDot: View {
    let tint: Color
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 18, height: 18)
                .scaleEffect(isPulsing ? 1.45 : 0.85)
                .opacity(isPulsing ? 0 : 1)
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 22, height: 22)
        .onAppear { isPulsing = true }
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)
    }
}


struct DashboardPreferenceSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var assetImage: String? = nil
    var isDanger = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                sectionIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text(subtitle)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(16)
        .background(isDanger ? PidgyDashboardTheme.red.opacity(0.075) : PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDanger ? PidgyDashboardTheme.red.opacity(0.24) : PidgyDashboardTheme.rule)
        )
    }

    @ViewBuilder
    private var sectionIcon: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: systemImage)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(isDanger ? PidgyDashboardTheme.red : PidgyDashboardTheme.brand)
                .frame(width: 22, height: 22)
                .background((isDanger ? PidgyDashboardTheme.red : PidgyDashboardTheme.brand).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

struct DashboardPreferenceRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(subtitle)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 24)

            trailing
        }
        .frame(minHeight: 46)
        .padding(.vertical, 6)
    }
}


private struct DashboardPreferencePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .pointerStyle(.link)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DashboardPreferenceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .pidgyCapsuleBackground()
        }
        .buttonStyle(DashboardPreferencePressStyle())
    }
}


struct DashboardPreferenceInlineStatus: View {
    let status: DashboardPreferenceStatus

    var body: some View {
        Text(status.text)
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(status.tint)
            .lineLimit(1)
    }
}


struct DashboardPreferenceMetric: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(PidgyDashboardTheme.captionMediumFont)
                .tracking(0.7)
                .foregroundStyle(PidgyDashboardTheme.tertiary)
            Text(value)
                .font(PidgyDashboardTheme.rowEmphasisFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(caption)
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(12)
        }
    }
}


struct DashboardGraphBreakdownSection: View {
    let title: String
    let rows: [GraphBuilder.DebugCountRow]
    let integerString: (Int) -> String

    var body: some View {
        DashboardPreferenceSection(title: title, subtitle: "Current graph store", systemImage: "list.bullet") {
            if rows.isEmpty {
                Text("No rows yet.")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                            .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                            .foregroundStyle(PidgyDashboardTheme.primary)
                        Spacer()
                        Text(integerString(row.count))
                            .font(PidgyDashboardTheme.metadataMediumFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                    .padding(.vertical, 8)

                    if row.id != rows.last?.id {
                        Rectangle()
                            .fill(PidgyDashboardTheme.rule)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

struct DashboardRoutingDebugCard: View {
    let snapshot: QueryRoutingDebugSnapshot
    let onUseQuery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.query)
                        .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(2)
                    Text("\(snapshot.spec.family.rawValue) -> \(snapshot.runtimeIntent.rawValue)")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Use") {
                    onUseQuery()
                }
                .buttonStyle(.plain)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.brand)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                routingLine("Engine", snapshot.spec.preferredEngine.rawValue)
                routingLine("Mode", snapshot.spec.mode.rawValue)
                routingLine("Scope", snapshot.spec.scope.rawValue)
                routingLine("Reply", snapshot.spec.replyConstraint.rawValue)
                routingLine("Confidence", String(format: "%.2f", snapshot.spec.parseConfidence))
                if !snapshot.spec.unsupportedFragments.isEmpty {
                    routingLine("Unsupported", snapshot.spec.unsupportedFragments.joined(separator: ", "))
                }
            }
        }
        .padding(12)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func routingLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(PidgyDashboardTheme.captionMediumFont)
                .foregroundStyle(PidgyDashboardTheme.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(PidgyDashboardTheme.captionFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
