import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main
struct InterviewAssistantApp: App {
    @AppStorage(AppPreferenceKey.themeMode) private var themeMode = AppThemeMode.dark.rawValue
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    #if os(macOS)
    @AppStorage(AppPreferenceKey.hideDockIcon) private var hideDockIcon = false
    #endif

    var sharedModelContainer: ModelContainer = {
        do {
            return try DataStorageManager.makeModelContainer()
        } catch {
            fatalError("Unable to open the local data store: \(error.localizedDescription)")
        }
    }()

    init() {
        // Keep the interview prompter out of screenshots/screen sharing by
        // default. `register` preserves an explicit choice made by the user.
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            AppPreferenceKey.hiddenFromScreenCapture: true
        ])
        // Existing builds persisted `false` automatically even when the user
        // never chose it. Migrate once to the new privacy-safe default; after
        // that, the Settings toggle remains fully user-controlled.
        if !defaults.bool(forKey: AppPreferenceKey.migratedHiddenFromScreenCaptureDefault) {
            defaults.set(true, forKey: AppPreferenceKey.hiddenFromScreenCapture)
            defaults.set(true, forKey: AppPreferenceKey.migratedHiddenFromScreenCaptureDefault)
        }
    }

    #if os(macOS)
    var body: some Scene {
        WindowGroup {
            rootContent
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Interview Assistant", systemImage: "sparkles") {
            Button(L.t("Show App")) {
                Self.showAppWindow()
            }
            Toggle(L.t("Hide Dock During Interview"), isOn: $hideDockIcon)
            Divider()
            Button(L.t("Quit")) {
                NSApp.terminate(nil)
            }
        }
    }
    #else
    var body: some Scene {
        WindowGroup {
            rootContent
        }
    }
    #endif

    private var rootContent: some View {
        ContentView()
            .modelContainer(sharedModelContainer)
            .environment(\.locale, currentLanguage.locale)
            .preferredColorScheme(currentTheme.colorScheme)
            .background(Color.appBG)
            .onAppear {
                #if os(macOS)
                Self.applyActivationPolicy(hideDockIcon: false)
                #endif
            }
    }

    private var currentTheme: AppThemeMode {
        AppThemeMode(rawValue: themeMode) ?? .dark
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    #if os(macOS)
    private static func applyActivationPolicy(hideDockIcon: Bool) {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    private static func showAppWindow() {
        NSApp.windows.forEach { window in
            guard !(window is PrompterPanel) else { return }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}
