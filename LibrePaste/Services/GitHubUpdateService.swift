//
//  GitHubUpdateService.swift
//  LibrePaste
//

import AppKit
import Foundation

public struct GitHubRelease: Sendable {
    public let version: String
    public let name: String
    public let pageURL: URL
    public let archiveURL: URL?
    public let publishedAt: Date?
}

public enum GitHubUpdateResult: Sendable {
    case updateAvailable(GitHubRelease)
    case upToDate
}

public enum GitHubUpdateError: LocalizedError {
    case invalidResponse
    case repositoryUnavailable
    case archiveUnavailable
    case applicationNotInstalled
    case invalidApplication
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid update response."
        case .repositoryUnavailable:
            return "The GitHub releases repository is unavailable."
        case .archiveUnavailable:
            return "This release does not contain a compatible ZIP archive."
        case .applicationNotInstalled:
            return "Move LibrePaste to Applications before installing updates."
        case .invalidApplication:
            return "The downloaded application failed security validation."
        case let .installationFailed(message):
            return "Unable to install the update: \(message)"
        }
    }
}

public final class GitHubUpdateService: @unchecked Sendable {
    public static let shared = GitHubUpdateService()

    // Updated to the authenticated user's public fork during repository setup.
    public static let repository = "minhdra/LibrePaste"
    public static let repositoryURL = URL(string: "https://github.com/\(repository)")!

    private let session: URLSession
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private init(session: URLSession = .shared) {
        self.session = session
    }

    public var automaticChecksEnabled: Bool {
        (DatabaseManager.shared.getSetting("automaticUpdateChecks") ?? "true") == "true"
    }

    public func checkForUpdates() async throws -> GitHubUpdateResult {
        let endpoint = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LibrePaste/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubUpdateError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw GitHubUpdateError.repositoryUnavailable
        }

        struct ReleaseResponse: Decodable {
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
            let htmlURL: URL
            let publishedAt: Date?
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name
                case htmlURL = "html_url"
                case publishedAt = "published_at"
                case assets
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let responseBody = try decoder.decode(ReleaseResponse.self, from: data)
        let latestVersion = Self.normalizedVersion(responseBody.tagName)
        let archiveURL = responseBody.assets.first(where: { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") &&
                (name.contains("arm64") || name.contains("universal") || !name.contains("x86_64"))
        })?.browserDownloadURL
        let release = GitHubRelease(
            version: latestVersion,
            name: responseBody.name ?? responseBody.tagName,
            pageURL: responseBody.htmlURL,
            archiveURL: archiveURL,
            publishedAt: responseBody.publishedAt
        )

        return Self.isVersion(latestVersion, newerThan: currentVersion)
            ? .updateAvailable(release)
            : .upToDate
    }

    @MainActor
    public func performAutomaticCheckIfNeeded() {
        guard automaticChecksEnabled else { return }

        let lastCheckValue = DatabaseManager.shared.getSetting("lastAutomaticUpdateCheck") ?? "0"
        let lastCheck = TimeInterval(lastCheckValue) ?? 0
        let now = Date().timeIntervalSince1970
        guard now - lastCheck >= checkInterval else { return }

        DatabaseManager.shared.setSetting(key: "lastAutomaticUpdateCheck", value: String(now))
        Task {
            guard case let .updateAvailable(release) = try? await checkForUpdates() else { return }
            promptForUpdate(release)
        }
    }

    @MainActor
    public func promptForUpdate(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("A new LibrePaste version is available")
        alert.informativeText = L10n.tr("Version %@ is available on GitHub.", release.version)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("Install and Relaunch"))
        alert.addButton(withTitle: L10n.tr("Open Download Page"))
        alert.addButton(withTitle: L10n.tr("Later"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                do {
                    try await downloadAndInstall(release)
                } catch {
                    presentInstallationError(error)
                }
            }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    public func downloadAndInstall(_ release: GitHubRelease) async throws {
        guard let archiveURL = release.archiveURL else {
            throw GitHubUpdateError.archiveUnavailable
        }

        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentAppURL.pathExtension == "app",
              !currentAppURL.path.hasPrefix("/Volumes/") else {
            throw GitHubUpdateError.applicationNotInstalled
        }

        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LibrePasteUpdate-\(UUID().uuidString)", isDirectory: true)
        let extractedDirectory = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        do {
            let (temporaryArchive, response) = try await session.download(from: archiveURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GitHubUpdateError.invalidResponse
            }
            let archive = workDirectory.appendingPathComponent("update.zip")
            try fileManager.moveItem(at: temporaryArchive, to: archive)

            try await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, extractedDirectory.path]
            )

            guard let downloadedApp = findApplication(in: extractedDirectory),
                  let downloadedBundle = Bundle(url: downloadedApp),
                  downloadedBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let downloadedVersion = downloadedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  Self.normalizedVersion(downloadedVersion) == Self.normalizedVersion(release.version) else {
                throw GitHubUpdateError.invalidApplication
            }

            try await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", downloadedApp.path]
            )

            try await scheduleReplacement(
                downloadedApp: downloadedApp,
                currentApp: currentAppURL,
                workDirectory: workDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    private func findApplication(in directory: URL) -> URL? {
        let directCandidate = directory.appendingPathComponent("LibrePaste.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: directCandidate.path) {
            return directCandidate
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { $0.pathExtension == "app" }
    }

    private func runProcess(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: GitHubUpdateError.installationFailed(
                        "\(executable.lastPathComponent) exited with status \(process.terminationStatus)"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @MainActor
    private func scheduleReplacement(
        downloadedApp: URL,
        currentApp: URL,
        workDirectory: URL
    ) async throws {
        let parentDirectory = currentApp.deletingLastPathComponent()
        let replacementScript = Self.replacementScript(
            processID: ProcessInfo.processInfo.processIdentifier,
            downloadedApp: downloadedApp,
            currentApp: currentApp,
            workDirectory: workDirectory
        )

        let process = Process()
        if FileManager.default.isWritableFile(atPath: parentDirectory.path) {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", replacementScript]
        } else {
            // macOS displays its standard administrator authorization dialog.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(Self.appleScriptLiteral(replacementScript)) with administrator privileges"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        NSApp.terminate(nil)
    }

    private static func replacementScript(
        processID: Int32,
        downloadedApp: URL,
        currentApp: URL,
        workDirectory: URL
    ) -> String {
        let source = shellQuote(downloadedApp.path)
        let target = shellQuote(currentApp.path)
        let backup = shellQuote(currentApp.path + ".previous")
        let work = shellQuote(workDirectory.path)
        return """
        while /bin/kill -0 \(processID) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(backup)
        /bin/mv \(target) \(backup) || exit 1
        if /usr/bin/ditto --rsrc --extattr --noqtn \(source) \(target); then
          /bin/rm -rf \(backup)
          /usr/bin/open \(target)
          /bin/rm -rf \(work)
        else
          /bin/rm -rf \(target)
          /bin/mv \(backup) \(target)
          /usr/bin/open \(target)
          exit 1
        fi
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    @MainActor
    private func presentInstallationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Update installation failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.runModal()
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func normalizedVersion(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value.split(separator: "-").first.map(String.init) ?? value
    }

    private static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let lhs = normalizedVersion(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let rhs = normalizedVersion(installed).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
