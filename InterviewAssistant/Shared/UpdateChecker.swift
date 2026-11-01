import Foundation

#if os(macOS)
import Combine
import Sparkle

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    let updaterController: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    private init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }
}

enum UpdateSuccessTracker {
    private static let lastVersionKey = "last_run_marketing_version"
    private static let lastBuildKey = "last_run_build_version"

    static func messageForCurrentLaunch(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> String? {
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let previousVersion = defaults.string(forKey: lastVersionKey)
        let previousBuild = defaults.string(forKey: lastBuildKey)

        defaults.set(currentVersion, forKey: lastVersionKey)
        defaults.set(currentBuild, forKey: lastBuildKey)

        guard let previousVersion,
              let previousBuild,
              currentBuild.compare(previousBuild, options: .numeric) == .orderedDescending else {
            return nil
        }

        return String(
            format: L.t("Interview AI was updated from %@ to %@."),
            previousVersion,
            currentVersion
        )
    }
}

#else
import Observation
import UIKit

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
        UIApplication.shared.open(url)
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
#endif
