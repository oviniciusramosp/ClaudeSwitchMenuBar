import Foundation

struct ClaudeUsageSnapshot: Codable, Sendable {
    let email: String
    let sessionUtilization: Double
    let weeklyUtilization: Double
    let sessionResetsAt: Date?
    let weeklyResetsAt: Date?
    let updatedAt: Date

    var sessionPercentText: String {
        Self.percentText(sessionUtilization)
    }

    var weeklyPercentText: String {
        Self.percentText(weeklyUtilization)
    }

    func effectiveWeeklyReset(using configuration: WeeklyResetConfiguration) -> Date? {
        if configuration.usesManualOverride {
            return configuration.nextResetDate()
        }
        return weeklyResetsAt
    }

    var weeklyWindowHasStarted: Bool {
        weeklyResetsAt != nil || weeklyUtilization > 0
    }

    func weeklyIdealUtilization(using configuration: WeeklyResetConfiguration) -> Double {
        guard weeklyWindowHasStarted || configuration.usesManualOverride else { return 0 }
        guard let weeklyResetsAt = effectiveWeeklyReset(using: configuration) else { return 0 }
        let weekDuration: TimeInterval = 7 * 24 * 60 * 60
        let start = weeklyResetsAt.addingTimeInterval(-weekDuration)
        let elapsed = Date().timeIntervalSince(start)
        return min(max(elapsed / weekDuration, 0), 1)
    }

    func weeklyIdealPercentText(using configuration: WeeklyResetConfiguration) -> String {
        Self.percentText(weeklyIdealUtilization(using: configuration))
    }

    func weeklyDeltaPercentagePoints(using configuration: WeeklyResetConfiguration) -> Double {
        (weeklyUtilization - weeklyIdealUtilization(using: configuration)) * 100
    }

    func isAboveExpected(using configuration: WeeklyResetConfiguration) -> Bool {
        guard weeklyWindowHasStarted || configuration.usesManualOverride else { return false }
        return weeklyDeltaPercentagePoints(using: configuration) > 0
    }

    func paceStatus(using configuration: WeeklyResetConfiguration) -> UsagePaceStatus {
        guard weeklyWindowHasStarted || configuration.usesManualOverride else { return .onPace }
        let delta = weeklyDeltaPercentagePoints(using: configuration)
        if delta > 3 {
            return .over
        }
        if abs(delta) >= 1 {
            return .warning
        }
        return .onPace
    }

    func paceLabel(using configuration: WeeklyResetConfiguration) -> String {
        guard weeklyWindowHasStarted || configuration.usesManualOverride else {
            return "Weekly window starts when you send a message"
        }
        let delta = weeklyDeltaPercentagePoints(using: configuration)
        switch paceStatus(using: configuration) {
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

    func weeklyResetText(using configuration: WeeklyResetConfiguration) -> String {
        if !weeklyWindowHasStarted && !configuration.usesManualOverride {
            return "Starts when a message is sent"
        }
        guard let weeklyResetsAt = effectiveWeeklyReset(using: configuration) else { return "Weekly reset unavailable" }
        let absolute = Self.resetDateFormatter.string(from: weeklyResetsAt)
        let relative = Self.relativeFormatter.localizedString(for: weeklyResetsAt, relativeTo: Date())
        return "\(absolute) (\(relative))"
    }

    var relativeUpdatedText: String {
        "updated \(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
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

enum UsagePaceStatus: String, Codable, Sendable {
    case onPace
    case warning
    case over
}

struct WeeklyResetConfiguration: Codable, Sendable {
    let usesManualOverride: Bool
    let weekday: Int
    let hour: Int
    let minute: Int

    func nextResetDate(from now: Date = Date(), calendar inputCalendar: Calendar = .current) -> Date? {
        var calendar = inputCalendar
        calendar.timeZone = .current

        var components = DateComponents()
        components.weekday = max(1, min(7, weekday))
        components.hour = max(0, min(23, hour))
        components.minute = max(0, min(59, minute))
        components.second = 0

        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

enum WeeklyResetOverrideStore {
    private static let defaultsKey = "weeklyResetOverridesByEmail"

    static func load(defaults: UserDefaults = .standard) -> [String: WeeklyResetConfiguration] {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode([String: WeeklyResetConfiguration].self, from: data)
        else {
            return [:]
        }
        return value
    }

    static func save(_ value: [String: WeeklyResetConfiguration], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum ClaudeUsageSnapshotStore {
    private static let defaultsKey = "claudeUsageSnapshotsByEmail"

    static func load(defaults: UserDefaults = .standard) -> [String: ClaudeUsageSnapshot] {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshots = try? JSONDecoder().decode([String: ClaudeUsageSnapshot].self, from: data)
        else {
            return [:]
        }
        return snapshots
    }

    static func save(_ snapshots: [String: ClaudeUsageSnapshot], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

struct ClaudeOAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

struct ClaudeUsageAPIResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

enum ClaudeUsageError: LocalizedError {
    case missingCurrentEmail
    case keychainReadFailed(OSStatus)
    case invalidCredentialPayload
    case missingAccessToken
    case refreshFailed(String)
    case usageFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCurrentEmail:
            return "Claude current account not found."
        case .keychainReadFailed(let status):
            return "Claude Keychain access failed (\(status))."
        case .invalidCredentialPayload:
            return "Claude credential payload is invalid."
        case .missingAccessToken:
            return "Claude access token is missing."
        case .refreshFailed(let message):
            return "Claude token refresh failed: \(message)"
        case .usageFetchFailed(let message):
            return "Claude usage fetch failed: \(message)"
        }
    }
}

enum ClaudeOAuthCredentialCacheStore {
    private static let defaultsKey = "claudeOAuthCredentialCacheByEmail"

    static func load(email: String) -> ClaudeOAuthCredentials? {
        let all = loadAll()
        guard let payload = all[normalized(email)]
        else {
            return nil
        }

        return ClaudeOAuthCredentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresAt
        )
    }

    static func save(_ credentials: ClaudeOAuthCredentials, email: String) {
        var all = loadAll()
        let payload = CachedOAuthPayload(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            expiresAt: credentials.expiresAt
        )
        all[normalized(email)] = payload
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadAll() -> [String: CachedOAuthPayload] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode([String: CachedOAuthPayload].self, from: data)
        else {
            return [:]
        }
        return payload
    }

    private struct CachedOAuthPayload: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }
}

extension ClaudeSwitcherService {
    func fetchCurrentClaudeUsage() async throws -> ClaudeUsageSnapshot? {
        guard let email = try loadCurrentEmail() else {
            throw ClaudeUsageError.missingCurrentEmail
        }

        let credentials = try await resolvedCredentials(for: email)
        let usage = try await fetchUsage(accessToken: credentials.accessToken, refreshToken: credentials.refreshToken, email: email)

        return ClaudeUsageSnapshot(
            email: email,
            sessionUtilization: normalizedUtilization(usage.fiveHour?.utilization),
            weeklyUtilization: normalizedUtilization(usage.sevenDay?.utilization),
            sessionResetsAt: usage.fiveHour?.resetsAt,
            weeklyResetsAt: usage.sevenDay?.resetsAt,
            updatedAt: Date()
        )
    }

    private func normalizedUtilization(_ value: Double?) -> Double {
        guard let value else { return 0 }
        if value >= 1 {
            return min(max(value / 100, 0), 1)
        }
        return min(max(value, 0), 1)
    }

    private func resolvedCredentials(for email: String) async throws -> ClaudeOAuthCredentials {
        if let cached = ClaudeOAuthCredentialCacheStore.load(email: email), !cached.isExpired {
            return cached
        }

        var credentials = try loadClaudeOAuthCredentialsFromKeychain()
        if credentials.isExpired, let refreshToken = credentials.refreshToken, !refreshToken.isEmpty {
            credentials = try await refreshClaudeOAuthCredentials(refreshToken: refreshToken, fallback: credentials)
        }

        ClaudeOAuthCredentialCacheStore.save(credentials, email: email)
        return credentials
    }

    private func fetchUsage(accessToken: String, refreshToken: String?, email: String) async throws -> ClaudeUsageAPIResponse {
        do {
            return try await requestUsage(accessToken: accessToken)
        } catch ClaudeUsageError.usageFetchFailed(let message) where message.contains("401") && refreshToken != nil {
            let refreshed = try await refreshClaudeOAuthCredentials(refreshToken: refreshToken ?? "", fallback: ClaudeOAuthCredentials(accessToken: accessToken, refreshToken: refreshToken, expiresAt: nil))
            ClaudeOAuthCredentialCacheStore.save(refreshed, email: email)
            return try await requestUsage(accessToken: refreshed.accessToken)
        }
    }

    private func requestUsage(accessToken: String) async throws -> ClaudeUsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeUsageError.usageFetchFailed("Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.usageFetchFailed("Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeUsageError.usageFetchFailed("HTTP \(http.statusCode) \(body)")
        }

        return try decoder.decode(ClaudeUsageAPIResponse.self, from: data)
    }

    private func refreshClaudeOAuthCredentials(refreshToken: String, fallback: ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials {
        guard let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            throw ClaudeUsageError.refreshFailed("Invalid token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.refreshFailed("Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeUsageError.refreshFailed("HTTP \(http.statusCode) \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return ClaudeOAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? fallback.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    private func loadClaudeOAuthCredentialsFromKeychain() throws -> ClaudeOAuthCredentials {
        let username = NSUserName()
        let result = try runCommandSync(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-a", username, "-w"]
        )
        guard let data = result.output.data(using: String.Encoding.utf8) else {
            throw ClaudeUsageError.invalidCredentialPayload
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            throw ClaudeUsageError.invalidCredentialPayload
        }

        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            throw ClaudeUsageError.missingAccessToken
        }

        let refreshToken = oauth["refreshToken"] as? String
        let expiresAtMilliseconds = oauth["expiresAt"] as? Double
        let expiresAt = expiresAtMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }

        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
