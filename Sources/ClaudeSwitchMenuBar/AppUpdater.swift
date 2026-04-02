import AppKit
import Foundation

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: String {
        tagName.replacingOccurrences(of: "v", with: "", options: [.anchored])
    }
}

struct AppUpdateRelease {
    let version: String
    let assetURL: URL
}

enum AppUpdateCheckResult {
    case upToDate(currentVersion: String)
    case updateAvailable(AppUpdateRelease)
    case noCompatibleAsset
}

enum AppUpdaterError: LocalizedError {
    case invalidReleaseURL
    case unexpectedResponse
    case downloadFailed
    case unzipFailed
    case installedAppNotFound
    case unsupportedInstallLocation

    var errorDescription: String? {
        switch self {
        case .invalidReleaseURL:
            return "Invalid GitHub Releases URL."
        case .unexpectedResponse:
            return "GitHub Releases returned an unexpected response."
        case .downloadFailed:
            return "Failed to download the release asset."
        case .unzipFailed:
            return "Failed to unpack the downloaded app update."
        case .installedAppNotFound:
            return "The downloaded app bundle could not be found."
        case .unsupportedInstallLocation:
            return "This app needs to be installed in ~/Applications to self-update safely."
        }
    }
}

struct AppUpdater {
    private let owner = "oviniciusramosp"
    private let repository = "ClaudeSwitchMenuBar"
    private let expectedAssetName = "Claude Switch.zip"

    func checkForUpdate() async throws -> AppUpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw AppUpdaterError.invalidReleaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeSwitchMenuBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppUpdaterError.unexpectedResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        guard isVersion(release.version, newerThan: currentVersion) else {
            return .upToDate(currentVersion: currentVersion)
        }

        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) ?? release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            return .noCompatibleAsset
        }

        return .updateAvailable(
            AppUpdateRelease(version: release.version, assetURL: asset.browserDownloadURL)
        )
    }

    func install(release: AppUpdateRelease) async throws {
        let currentAppURL = Bundle.main.bundleURL
        let applicationsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard currentAppURL.path.hasPrefix(applicationsURL.path) else {
            throw AppUpdaterError.unsupportedInstallLocation
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSwitchUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let zipURL = tempDirectory.appendingPathComponent(expectedAssetName)
        let (downloadedURL, _) = try await URLSession.shared.download(from: release.assetURL)
        try FileManager.default.moveItem(at: downloadedURL, to: zipURL)

        let unpackDirectory = tempDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackDirectory, withIntermediateDirectories: true)

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-x", "-k", zipURL.path, unpackDirectory.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        guard unzipProcess.terminationStatus == 0 else {
            throw AppUpdaterError.unzipFailed
        }

        let installedAppURL = try locateAppBundle(in: unpackDirectory)
        try scheduleReplacement(from: installedAppURL, to: currentAppURL)
        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private func locateAppBundle(in directory: URL) throws -> URL {
        if directory.pathExtension == "app" {
            return directory
        }

        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "app" {
                return url
            }
        }

        throw AppUpdaterError.installedAppNotFound
    }

    private func scheduleReplacement(from downloadedAppURL: URL, to destinationURL: URL) throws {
        let script = """
        sleep 1
        rm -rf "\(destinationURL.path)"
        cp -R "\(downloadedAppURL.path)" "\(destinationURL.path)"
        open "\(destinationURL.path)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        try process.run()
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }

        return false
    }
}
