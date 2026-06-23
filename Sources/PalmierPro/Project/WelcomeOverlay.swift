import AppKit
import SwiftUI

/// First-launch welcome shown over the Home screen
struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    private static let hero: NSImage? = loadHero()

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 520)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Welcome to Palmier Slate")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("A lightweight video editor with MCP.")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            heroImage
            HStack {
                Spacer()
                Button("Get Started") { onDismiss() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    @ViewBuilder
    private var heroImage: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private static func loadHero() -> NSImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/welcome-butterfly.jpg"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Images/welcome-butterfly.jpg"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
