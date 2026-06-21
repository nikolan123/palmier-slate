import SwiftUI

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var appState = AppState.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            if appState.claudeIntegrationEnabled {
                Button(action: { editor.agentPanelVisible.toggle() }) {
                    Image(systemName: editor.agentPanelVisible ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.aiGradient)
                        .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Toggle Agent Panel")
            }
        }
    }
}
