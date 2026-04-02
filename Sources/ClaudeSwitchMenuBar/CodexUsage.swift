import Foundation

struct CodexUsageSnapshot: Codable, Sendable {
    let email: String
    let planType: String?
    let sessionUtilization: Double
    let weeklyUtilization: Double
    let sessionResetsAt: Date?
    let weeklyResetsAt: Date?
    let updatedAt: Date

    var sessionPercentText: String {
        "\(Int((sessionUtilization * 100).rounded()))%"
    }

    var weeklyPercentText: String {
        "\(Int((weeklyUtilization * 100).rounded()))%"
    }

    var weeklyIdealUtilization: Double {
        guard let weeklyResetsAt else { return 0 }
        let weekDuration: TimeInterval = 7 * 24 * 60 * 60
        let start = weeklyResetsAt.addingTimeInterval(-weekDuration)
        let elapsed = Date().timeIntervalSince(start)
        return min(max(elapsed / weekDuration, 0), 1)
    }

    var weeklyIdealPercentText: String {
        "\(Int((weeklyIdealUtilization * 100).rounded()))%"
    }

    var weeklyDeltaPercentagePoints: Double {
        (weeklyUtilization - weeklyIdealUtilization) * 100
    }

    var isAboveExpected: Bool {
        weeklyDeltaPercentagePoints > 0
    }

    var paceStatus: UsagePaceStatus {
        let delta = weeklyDeltaPercentagePoints
        if delta > 3 {
            return .over
        }
        if abs(delta) >= 1 {
            return .warning
        }
        return .onPace
    }

    var paceLabel: String {
        let delta = weeklyDeltaPercentagePoints
        switch paceStatus {
        case .onPace:
            return "On pace"
        case .warning:
            if delta >= 0 {
                return String(format: "Slightly above pace (+%.1f%%)", delta)
            }
            return String(format: "Slightly below pace (%.1f%%)", delta)
        case .over:
            return String(format: "Above pace (+%.1f%%)", delta)
        }
    }

    var relativeUpdatedText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "updated \(formatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }

    var weeklyResetText: String {
        guard let weeklyResetsAt else { return "Weekly reset unavailable" }
        let absolute = Self.resetDateFormatter.string(from: weeklyResetsAt)
        let relative = Self.relativeFormatter.localizedString(for: weeklyResetsAt, relativeTo: Date())
        return "\(absolute) (\(relative))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

enum CodexUsageSnapshotStore {
    private static let defaultsKey = "codexUsageSnapshot"

    static func load(defaults: UserDefaults = .standard) -> CodexUsageSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: CodexUsageSnapshot?, defaults: UserDefaults = .standard) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

struct CodexOAuthCredentials {
    let accessToken: String
    let refreshToken: String
    let accountId: String?
    let lastRefresh: Date?

    var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > (8 * 24 * 60 * 60)
    }
}

struct CodexUsageResponse: Decodable {
    let email: String?
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateWindow?
    let secondaryWindow: CodexRateWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexRateWindow: Decodable {
    let usedPercent: Int
    let resetAfterSeconds: Int?
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

extension ClaudeSwitcherService {
    func fetchCodexUsage() async throws -> CodexUsageSnapshot? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            return nil
        }

        var credentials = try loadCodexCredentials()
        if credentials.needsRefresh && !credentials.refreshToken.isEmpty {
            credentials = try await refreshCodexCredentials(credentials)
            try saveCodexCredentials(credentials)
        }

        let usage = try await requestCodexUsage(credentials: credentials)
        let session = usage.rateLimit?.primaryWindow
        let weekly = usage.rateLimit?.secondaryWindow

        return CodexUsageSnapshot(
            email: usage.email ?? "Codex account",
            planType: usage.planType,
            sessionUtilization: Double(session?.usedPercent ?? 0) / 100,
            weeklyUtilization: Double(weekly?.usedPercent ?? 0) / 100,
            sessionResetsAt: codexResetDate(for: session),
            weeklyResetsAt: codexResetDate(for: weekly),
            updatedAt: Date()
        )
    }

    func openCodexApp() async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try runCommandSync(
                executablePath: "/usr/bin/open",
                arguments: ["/Applications/Codex.app"]
            )
        }.value
    }

    private func loadCodexCredentials() throws -> CodexOAuthCredentials {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: authURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSwitcherError.commandFailed("Failed to decode Codex auth.json")
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String
        else {
            throw ClaudeSwitcherError.commandFailed("Codex auth.json is missing tokens")
        }

        let accountId = tokens["account_id"] as? String
        let lastRefresh: Date? = {
            guard let value = json["last_refresh"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }()

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId,
            lastRefresh: lastRefresh
        )
    }

    private func saveCodexCredentials(_ credentials: CodexOAuthCredentials) throws {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: authURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSwitcherError.commandFailed("Failed to update Codex auth.json")
        }
        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: authURL, options: .atomic)
    }

    private func refreshCodexCredentials(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            throw ClaudeSwitcherError.commandFailed("Invalid Codex token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeSwitcherError.commandFailed("Failed to refresh Codex token")
        }

        return CodexOAuthCredentials(
            accessToken: (json["access_token"] as? String) ?? credentials.accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? credentials.refreshToken,
            accountId: credentials.accountId,
            lastRefresh: Date()
        )
    }

    private func requestCodexUsage(credentials: CodexOAuthCredentials) async throws -> CodexUsageResponse {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let configText = try? String(contentsOf: configURL)
        var baseURL = "https://chatgpt.com/backend-api"
        if let line = configText?.split(whereSeparator: \.isNewline).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("chatgpt_base_url") }),
           let rawValue = line.split(separator: "=", maxSplits: 1).last
        {
            baseURL = rawValue.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        let path = baseURL.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        guard let url = URL(string: baseURL + path) else {
            throw ClaudeSwitcherError.commandFailed("Invalid Codex usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeSwitcherError.commandFailed("Invalid Codex usage response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ClaudeSwitcherError.commandFailed("Codex auth expired. Open Codex to sign in again.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeSwitcherError.commandFailed("Codex usage error \(http.statusCode): \(body)")
        }

        return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }

    private func codexResetDate(for window: CodexRateWindow?) -> Date? {
        guard let window else { return nil }
        if let resetAfterSeconds = window.resetAfterSeconds {
            return Date().addingTimeInterval(TimeInterval(resetAfterSeconds))
        }
        return Date(timeIntervalSince1970: TimeInterval(window.resetAt))
    }
}
