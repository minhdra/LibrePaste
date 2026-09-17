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
    public let publishedAt: Date?
}

public enum GitHubUpdateResult: Sendable {
    case updateAvailable(GitHubRelease)
    case upToDate
}

public enum GitHubUpdateError: LocalizedError {
    case invalidResponse
    case repositoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid update response."
        case .repositoryUnavailable:
            return "The GitHub releases repository is unavailable."
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
            let tagName: String
            let name: String?
            let htmlURL: URL
            let publishedAt: Date?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name
                case htmlURL = "html_url"
                case publishedAt = "published_at"
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let responseBody = try decoder.decode(ReleaseResponse.self, from: data)
        let latestVersion = Self.normalizedVersion(responseBody.tagName)
        let release = GitHubRelease(
            version: latestVersion,
            name: responseBody.name ?? responseBody.tagName,
            pageURL: responseBody.htmlURL,
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
            presentUpdateAlert(release)
        }
    }

    @MainActor
    private func presentUpdateAlert(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("A new LibrePaste version is available")
        alert.informativeText = L10n.tr("Version %@ is available on GitHub.", release.version)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("Open Download Page"))
        alert.addButton(withTitle: L10n.tr("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
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
