import SwiftUI
import SwiftData
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main
struct InterviewAssistantApp: App {
    @AppStorage(AppPreferenceKey.themeMode) private var themeMode = AppThemeMode.dark.rawValue
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @State private var updateChecker = UpdateChecker.shared
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
            Button(updateChecker.isChecking ? L.t("Checking for Updates...") : L.t("Check for Updates...")) {
                Self.showAppWindow()
                Task { await updateChecker.check(manual: true) }
            }
            .disabled(updateChecker.isChecking)
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
                Task { await updateChecker.checkAtLaunchIfNeeded() }
            }
            .alert(updateChecker.alertTitle, isPresented: Binding(
                get: { updateChecker.isPresentingResult },
                set: { updateChecker.isPresentingResult = $0 }
            )) {
                if updateChecker.availableRelease != nil {
                    Button(L.t("Download Update")) { updateChecker.openDownload() }
                    Button(L.t("Later"), role: .cancel) {}
                } else {
                    Button(L.t("OK"), role: .cancel) {}
                }
            } message: {
                Text(updateChecker.alertMessage)
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

@MainActor
@Observable
final class UpdateChecker {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, assets
            case htmlURL = "html_url"
        }

        var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
        var downloadURL: URL { assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadURL ?? htmlURL }
    }

    static let shared = UpdateChecker()

    var isChecking = false
    var isPresentingResult = false
    var availableRelease: Release?
    var alertTitle = ""
    var alertMessage = ""
    var statusText = ""

    private var didCheckThisLaunch = false
    private let endpoint = URL(string: "https://api.github.com/repos/pennyzhaozhao/AI-interview-Assistant/releases/latest")!

    func checkAtLaunchIfNeeded() async {
        guard !didCheckThisLaunch else { return }
        didCheckThisLaunch = true
        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        statusText = L.t("Checking for Updates...")
        defer { isChecking = false }

        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 12
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("InterviewAssistant", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if Self.compareVersions(release.version, current) == .orderedDescending {
                availableRelease = release
                alertTitle = String(format: L.t("Version %@ is available"), release.version)
                let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                alertMessage = notes.isEmpty ? L.t("A newer version is ready to download.") : String(notes.prefix(1600))
                statusText = alertTitle
                isPresentingResult = true
            } else {
                availableRelease = nil
                alertTitle = L.t("You're up to date")
                alertMessage = String(format: L.t("InterviewAssistant %@ is the latest version."), current)
                statusText = alertMessage
                if manual { isPresentingResult = true }
            }
        } catch {
            availableRelease = nil
            alertTitle = L.t("Unable to Check for Updates")
            alertMessage = L.t("Check your internet connection and try again.")
            statusText = alertTitle
            if manual { isPresentingResult = true }
        }
    }

    func openDownload() {
        guard let url = availableRelease?.downloadURL else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }
}
