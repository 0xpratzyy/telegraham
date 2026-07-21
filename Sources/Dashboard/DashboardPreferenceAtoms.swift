import SwiftUI

// MARK: - V2 Preferences building blocks (matches the design system handoff)
//
// These are the Section / SectionHead / Field / MinInput / Pill / GhostBtn /
// Toggle / StatTile / HBarChart / Sparkline / Donut atoms from the design's
// Preferences.jsx, ported to SwiftUI on top of PidgyTokens. The older
// DashboardPreference* components (diagnostics page only) live in
// DashboardPreferenceDiagnostics.swift.

struct PrefSection<Content: View>: View {
    var topPadding: CGFloat = 24
    var bottomBorder: Bool = true
    let content: () -> Content

    init(topPadding: CGFloat = 24, bottomBorder: Bool = true, @ViewBuilder _ content: @escaping () -> Content) {
        self.topPadding = topPadding
        self.bottomBorder = bottomBorder
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.top, topPadding)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if bottomBorder {
                Rectangle()
                    .fill(Color.Pidgy.border1)
                    .frame(height: 1)
            }
        }
    }
}

struct PrefSectionHead<Action: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font.Pidgy.sectionTitle)
                    .tracking(-0.4)
                    .foregroundStyle(Color.Pidgy.fg1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.bottom, 18)
    }
}

extension PrefSectionHead where Action == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, action: { EmptyView() })
    }
}

/// Form field row used across the v2 Preferences design.
/// `content` renders below the label/hint pair; `right` floats trailing.
/// Pass `nil` for either to omit. Avoids generic-init ambiguity.
struct PrefField: View {
    let label: String
    var hint: String?
    var content: AnyView?
    var right: AnyView?

    init(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> some View = { EmptyView() },
        @ViewBuilder right: () -> some View = { EmptyView() }
    ) {
        self.label = label
        self.hint = hint
        let body = content()
        if body is EmptyView {
            self.content = nil
        } else {
            self.content = AnyView(body)
        }
        let rightView = right()
        if rightView is EmptyView {
            self.right = nil
        } else {
            self.right = AnyView(rightView)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg1)
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                if let content {
                    content.padding(.top, 8)
                }
            }
            Spacer(minLength: 12)
            if let right {
                right
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.Pidgy.border1)
                .frame(height: 1)
        }
    }
}

/// Borderless input — only a 1pt bottom hairline. Bound to a String, plain
/// text or password.
struct PrefMinInput: View {
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false
    var monospaced: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(monospaced ? Font.Pidgy.mono : .system(size: 13))
        .foregroundStyle(Color.Pidgy.fg1)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.Pidgy.border2)
                .frame(height: 1)
        }
    }
}

struct PrefPill: View {
    enum Tone { case green, red, blue, amber, mono }
    let text: String
    var tone: Tone = .green

    private var fg: Color {
        switch tone {
        case .green: return Color.Pidgy.success
        case .red: return Color.Pidgy.danger
        case .blue: return Color.Pidgy.accentFg
        case .amber: return Color.Pidgy.warning
        case .mono: return Color.Pidgy.fg2
        }
    }

    private var bg: Color {
        switch tone {
        case .green: return Color.Pidgy.success.opacity(0.10)
        case .red: return Color.Pidgy.danger.opacity(0.12)
        case .blue: return Color.Pidgy.accentFg.opacity(0.12)
        case .amber: return Color.Pidgy.warning.opacity(0.12)
        case .mono: return .clear
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(fg).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(fg)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(bg))
    }
}

struct PrefGhostButton: View {
    let title: String
    var systemImage: String?
    var tone: Tone = .neutral
    let action: () -> Void

    enum Tone { case neutral, danger }

    @State private var isHovering = false

    private var fg: Color {
        tone == .danger ? Color.Pidgy.danger : Color.Pidgy.fg1
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.Pidgy.bg2 : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.Pidgy.border2)
                    )
            )
        }
        .buttonStyle(.pidgyPress)
        .onHover { isHovering = $0 }
        .animation(PidgyMotion.hover, value: isHovering)
    }
}

struct PrefToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.Pidgy.accentFg : Color.Pidgy.bg3)
                    .overlay(
                        Capsule().stroke(isOn ? Color.Pidgy.accentFg : Color.Pidgy.border2)
                    )
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.30), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(PidgyMotion.easeOut, value: isOn)
    }
}

/// Compact value picker for preference rows — a borderless Menu
/// rendered as a small bordered chip, visually paired with PrefToggle.
struct PrefOptionMenu: View {
    let options: [(value: Int, label: String)]
    @Binding var selection: Int

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "\(selection) days"
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.Pidgy.fg1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.Pidgy.bg3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.Pidgy.border2)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Stat tile: small dot + uppercase eyebrow / display value / hint.
/// No card chrome — sits in a grid with an inset divider on top.
struct PrefStatTile: View {
    enum Dot { case blue, green, amber, red }
    let eyebrow: String
    let value: String
    var hint: String?
    var dot: Dot = .blue
    var hasTopBorder: Bool = true

    private var dotColor: Color {
        switch dot {
        case .blue: return Color.Pidgy.accentFg
        case .green: return Color.Pidgy.success
        case .amber: return Color.Pidgy.warning
        case .red: return Color.Pidgy.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 5, height: 5)
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.85)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Pidgy.fg3)
            }
            Text(value)
                .font(Font.Pidgy.statValue)
                .tracking(-0.4)
                .foregroundStyle(Color.Pidgy.fg1)
                .lineLimit(1)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            if hasTopBorder {
                Rectangle().fill(Color.Pidgy.border1).frame(height: 1)
            }
        }
    }
}

// MARK: - Charts

struct PrefBarRow: Identifiable {
    let id: String
    let label: String
    let value: Double
    let right: String
    let sub: String
    let color: Color
}

struct PrefHBarChart: View {
    let rows: [PrefBarRow]
    var max: Double {
        Swift.max(rows.map(\.value).max() ?? 1, 0.0001)
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows) { row in
                let pct = row.value / max
                HStack(spacing: 14) {
                    Text(row.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg2)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.Pidgy.bg3)
                                .frame(height: 8)
                            Capsule()
                                .fill(row.color)
                                .frame(width: max == 0 ? 0 : proxy.size.width * pct, height: 8)
                        }
                    }
                    .frame(height: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(row.right)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Pidgy.fg1)
                            .monospacedDigit()
                        Text(row.sub)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Pidgy.fg4)
                            .monospacedDigit()
                    }
                    .frame(width: 90, alignment: .trailing)
                }
            }
        }
    }
}

struct PrefSparkline: View {
    let data: [Double]
    var color: Color = Color.Pidgy.accentFg
    var height: CGFloat = 56
    var fill: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pad: CGFloat = 4
            let drawableWidth = width - pad * 2
            let drawableHeight = height - pad * 2
            let maxValue = data.max() ?? 1
            let minValue = data.min() ?? 0
            let range = Swift.max(maxValue - minValue, 0.0001)

            let points: [CGPoint] = data.enumerated().map { idx, value in
                let denom = Swift.max(data.count - 1, 1)
                let x = pad + drawableWidth * CGFloat(idx) / CGFloat(denom)
                let y = pad + drawableHeight * (1 - CGFloat((value - minValue) / range))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                if fill, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: height - pad))
                        for point in points {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: height - pad))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                }
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(color)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
        .frame(height: height)
    }
}

struct PrefDonut: View {
    /// 0..1 fraction filled.
    let progress: Double
    let label: String
    var sub: String?
    var color: Color = Color.Pidgy.success
    var size: CGFloat = 92
    var lineWidth: CGFloat = 6

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.Pidgy.bg3, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Font.Pidgy.statValue)
                    .tracking(-0.4)
                    .foregroundStyle(Color.Pidgy.fg1)
                if let sub, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
            }
        }
    }
}

/// Sidebar nav row for the v2 Preferences design — flat, icon + label, with
/// hover that lifts color from fg-3 to fg-1, and selected state that uses
/// the bg-2 fill from the design.
struct PrefRailRow: View {
    let page: DashboardPreferencePage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var fg: Color {
        if isSelected {
            return Color.Pidgy.fg1
        }
        return isHovering ? Color.Pidgy.fg1 : Color.Pidgy.fg3
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PidgyMotion.easeOutFast, value: isHovering)
        .animation(PidgyMotion.easeOutFast, value: isSelected)
    }
}
