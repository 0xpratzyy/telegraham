import SwiftUI

/// The sidebar collapse/expand control that lives in the dashboard
/// window's title bar, immediately to the right of the traffic
/// lights (Granola convention). Hosted via an
/// `NSTitlebarAccessoryViewController` in AppDelegate. Posts
/// `.pidgyToggleSidebar`; DashboardView observes and animates the
/// actual collapse so the title-bar control stays decoupled from the
/// view's `@AppStorage` state.
struct SidebarToggleTitlebarButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .pidgyToggleSidebar, object: nil)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHovering ? 0.85 : 0.55))
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Toggle sidebar (⌘S)")
        // Nudge off the green traffic light a touch.
        .padding(.leading, 6)
    }
}
