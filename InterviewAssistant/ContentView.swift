import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppSection: String, CaseIterable, Identifiable {
    case interview
    case sender
    case knowledge
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interview: return L.t("Interview")
        case .sender: return L.t("Director Mode")
        case .knowledge: return L.t("Knowledge Base")
        case .history: return L.t("History")
        case .settings: return L.t("Settings")
        }
    }

    var mobileTitle: String {
        switch self {
        case .interview: return L.t("Home")
        case .knowledge: return L.t("Knowledge")
        case .history: return L.t("History")
        case .settings: return L.t("Settings")
        case .sender: return L.t("Director")
        }
    }

    var icon: String {
        switch self {
        case .interview: return "sparkles"
        case .sender: return "person.wave.2.fill"
        case .knowledge: return "folder.fill"
        case .history: return "clock.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.themeMode) private var themeMode = AppThemeMode.dark.rawValue
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @State private var selection: AppSection = .interview
    @State private var activeKBIDs = Set<UUID>()
    @State private var isSidebarCollapsed = false
    @State private var isKeyboardVisible = false
    @State private var keyboardObserverTokens: [NSObjectProtocol] = []
    @State private var mockLaunchConfig: MockInterviewLaunchConfig?

    var body: some View {
        Group {
            if isCompact {
                mobileShell
            } else {
                desktopShell
            }
        }
        .background(appBackground)
        .foregroundStyle(Color.appText)
        .environment(\.locale, currentLanguage.locale)
        .preferredColorScheme(currentTheme.colorScheme)
        .onAppear {
            installKeyboardObservers()
        }
        .onDisappear {
            removeKeyboardObservers()
        }
    }

    private var desktopShell: some View {
        HStack(spacing: 0) {
            if mockLaunchConfig == nil {
                sidebar
                Divider()
                    .overlay(Color.appBorder)
            }
            currentScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(isSidebarCollapsed)
        }
        .frame(minWidth: 1180, minHeight: 760)
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
    }

    private var mobileShell: some View {
        ZStack {
            currentScreen
        }
        .safeAreaInset(edge: .bottom) {
            if !isKeyboardVisible && mockLaunchConfig == nil {
                mobileTabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isKeyboardVisible)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                    .frame(width: 38, height: 38)

                    if !isSidebarCollapsed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Interview AI")
                                .font(.appBodyMedium)
                            Text(L.t("AI-native prep"))
                                .font(.appSmall)
                                .foregroundStyle(Color.appMuted)
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                ForEach(visibleSections) { section in
                    sidebarButton(section)
                }
            }

            Spacer()

            Button {
                isSidebarCollapsed.toggle()
            } label: {
                Image(systemName: isSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.appButton)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.button, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(isSidebarCollapsed ? 12 : 18)
        .frame(width: isSidebarCollapsed ? 72 : 280)
        .background(Color.appSurface.opacity(0.5))
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                if !isSidebarCollapsed {
                    Text(section.title)
                        .font(.appCaptionMedium)
                    Spacer()
                }
            }
            .foregroundStyle(selection == section ? Color.appText : Color.appMuted)
            .padding(.horizontal, isSidebarCollapsed ? 0 : 14)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(selection == section ? Color.appButton : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(section.title)
    }

    private var mobileTabBar: some View {
        HStack(spacing: 4) {
            ForEach(visibleSections) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(section.mobileTitle)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(mobileSelection == section ? Color.appText : Color.appMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(mobileSelection == section ? Color.appButton : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .background(Color.appSurface.opacity(0.86))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.appBorder), alignment: .top)
    }

    @ViewBuilder
    private var currentScreen: some View {
        if let mockLaunchConfig {
            MockInterviewView(config: mockLaunchConfig) {
                self.mockLaunchConfig = nil
                self.selection = .interview
            }
        } else {
            screen(for: visibleSections.contains(selection) ? selection : .interview)
        }
    }

    @ViewBuilder
    private func screen(for section: AppSection) -> some View {
        switch section {
        case .interview:
            SetupView(
                activeIDs: $activeKBIDs,
                onOpenKnowledge: { selection = .knowledge },
                onOpenAPISettings: { selection = .settings },
                onOpenMockInterview: { config in mockLaunchConfig = config }
            )
        case .sender:
            SenderView()
        case .knowledge:
            KnowledgeBaseManagerView(activeIDs: $activeKBIDs)
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }

    private var mobileSelection: AppSection {
        visibleSections.contains(selection) ? selection : .interview
    }

    private var visibleSections: [AppSection] {
        [.interview, .sender, .knowledge, .history, .settings]
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var currentTheme: AppThemeMode {
        AppThemeMode(rawValue: themeMode) ?? .dark
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private var appBackground: some View {
        ZStack {
            Color.appBG.ignoresSafeArea()
            RadialGradient(
                colors: [Color.appPrimary.opacity(currentTheme == .dark ? 0.22 : 0.09), Color.clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }

    private func installKeyboardObservers() {
        #if os(iOS)
        guard keyboardObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let willShow = center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                isKeyboardVisible = true
            }
        }
        let willHide = center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                isKeyboardVisible = false
            }
        }
        keyboardObserverTokens = [willShow, willHide]
        #endif
    }

    private func removeKeyboardObservers() {
        #if os(iOS)
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObserverTokens = []
        #endif
    }

}
