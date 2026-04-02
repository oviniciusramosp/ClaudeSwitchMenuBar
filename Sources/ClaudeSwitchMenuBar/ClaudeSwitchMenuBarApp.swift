import AppKit
import Combine
import Foundation
import SwiftUI

@main
struct ClaudeSwitchMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
                .frame(width: 380)
        } label: {
            if store.menuBarUsageSource == .codex {
                CodexMenuBarUsageIconView(snapshot: store.codexSnapshot)
            } else {
                MenuBarUsageIconView(
                    snapshot: store.currentUsageSnapshot,
                    configuration: store.weeklyResetConfiguration
                )
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum AppTab: Hashable {
    case claude
    case codex
    case settings
}

enum MenuBarUsageSource: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        }
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @AppStorage("autoRestartClaudeAfterSwitch") var autoRestartClaudeAfterSwitch = true
    @AppStorage("menuBarUsageSource") private var menuBarUsageSourceRawValue = MenuBarUsageSource.claude.rawValue
    @Published private(set) var accounts: [ManagedAccount] = []
    @Published private(set) var currentEmail: String?
    @Published private(set) var managedCurrentAccountNumber: Int?
    @Published private(set) var isBusy = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published private(set) var usageByEmail: [String: ClaudeUsageSnapshot] = [:]
    @Published private(set) var codexSnapshot: CodexUsageSnapshot?
    @Published var settingsAccountEmail: String?

    private let service = ClaudeSwitcherService()
    private var refreshTimer: Timer?
    private var weeklyResetOverridesByEmail: [String: WeeklyResetConfiguration] = [:]

    init() {
        usageByEmail = ClaudeUsageSnapshotStore.load()
        codexSnapshot = CodexUsageSnapshotStore.load()
        weeklyResetOverridesByEmail = WeeklyResetOverrideStore.load()
        refresh(forceUsageRefresh: true)
        startUsageRefreshLoop()
    }

    var canAddCurrentAccount: Bool {
        guard let currentEmail else { return false }
        return !accounts.contains(where: { $0.email == currentEmail })
    }

    var currentUsageSnapshot: ClaudeUsageSnapshot? {
        guard let currentEmail else { return nil }
        return usageSnapshot(for: currentEmail)
    }

    var menuBarUsageSource: MenuBarUsageSource {
        get { MenuBarUsageSource(rawValue: menuBarUsageSourceRawValue) ?? .claude }
        set { menuBarUsageSourceRawValue = newValue.rawValue }
    }

    var weeklyResetConfiguration: WeeklyResetConfiguration {
        configuration(for: currentEmail)
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh(forceUsageRefresh: Bool = false) {
        do {
            let snapshot = try service.loadSnapshot()
            accounts = snapshot.accounts
            currentEmail = snapshot.currentEmail
            managedCurrentAccountNumber = snapshot.managedCurrentAccountNumber
            if settingsAccountEmail == nil {
                settingsAccountEmail = snapshot.currentEmail ?? snapshot.accounts.first?.email
            } else if let settingsAccountEmail,
                      !snapshot.accounts.contains(where: { $0.email == settingsAccountEmail }) {
                self.settingsAccountEmail = snapshot.currentEmail ?? snapshot.accounts.first?.email
            }
            if snapshot.accounts.isEmpty {
                statusMessage = "No managed accounts yet"
            } else if let managedCurrentAccountNumber,
                      let account = snapshot.accounts.first(where: { $0.number == managedCurrentAccountNumber }) {
                statusMessage = "Active: \(account.email)"
            } else if let currentEmail {
                statusMessage = "Current Claude login: \(currentEmail)"
            } else {
                statusMessage = "Claude account not detected"
            }
            errorMessage = nil
        } catch {
            accounts = []
            currentEmail = nil
            managedCurrentAccountNumber = nil
            statusMessage = "Unable to load state"
            errorMessage = error.localizedDescription
        }

        Task {
            await refreshCurrentUsageIfNeeded(force: forceUsageRefresh)
            await refreshCodexUsageIfNeeded(force: forceUsageRefresh)
        }
    }

    func addCurrentAccount() {
        runOperation(successMessage: "Current account added") {
            _ = try await self.service.runCCSwitch(arguments: ["--add-account"])
            if let usageSnapshot = try await self.service.fetchCurrentClaudeUsage() {
                await MainActor.run {
                    self.storeUsageSnapshot(usageSnapshot)
                }
            }
        }
    }

    func logoutClaude() {
        runOperation(successMessage: "Logged out. Use browser login for the next account.") {
            _ = try await self.service.runClaudeAuth(arguments: ["auth", "logout"])
        }
    }

    func loginClaudeInBrowser() {
        runOperation(successMessage: "Browser login completed and account added.") {
            _ = try await self.service.runClaudeAuth(arguments: ["auth", "login"])
            let snapshot = try self.service.loadSnapshot()
            if let currentEmail = snapshot.currentEmail,
               !snapshot.accounts.contains(where: { $0.email == currentEmail }) {
                _ = try await self.service.runCCSwitch(arguments: ["--add-account"])
            }
            if let usageSnapshot = try await self.service.fetchCurrentClaudeUsage() {
                await MainActor.run {
                    self.storeUsageSnapshot(usageSnapshot)
                }
            }
        }
    }

    func switchToAccount(_ account: ManagedAccount) {
        let shouldRestart = autoRestartClaudeAfterSwitch
        let successMessage = shouldRestart
            ? "Switched to \(account.email) and restarted Claude Code."
            : "Switched to \(account.email). Restart Claude Code to apply it."

        runOperation(successMessage: successMessage) {
            if let currentUsage = try await self.service.fetchCurrentClaudeUsage() {
                await MainActor.run {
                    self.storeUsageSnapshot(currentUsage)
                }
            }
            if shouldRestart {
                await self.service.quitClaudeDesktopIfRunning()
            }
            _ = try await self.service.runCCSwitch(arguments: ["--switch-to", String(account.number)])
            if let newUsage = try await self.service.fetchCurrentClaudeUsage() {
                await MainActor.run {
                    self.storeUsageSnapshot(newUsage)
                }
            }
            if shouldRestart {
                try await self.service.launchClaudeDesktop()
            }
        }
    }

    func usageSnapshot(for email: String) -> ClaudeUsageSnapshot? {
        usageByEmail[Self.normalizedEmailKey(email)]
    }

    func connectCodex() {
        runOperation(successMessage: "Opened Codex. Sign in there, then refresh here.") {
            try await self.service.openCodexApp()
        }
    }

    func configuration(for email: String?) -> WeeklyResetConfiguration {
        guard let email else {
            return Self.defaultWeeklyResetConfiguration
        }
        return weeklyResetOverridesByEmail[Self.normalizedEmailKey(email)] ?? Self.defaultWeeklyResetConfiguration
    }

    func setWeeklyResetManualOverride(_ value: Bool, for email: String?) {
        updateConfiguration(for: email) { config in
            config = WeeklyResetConfiguration(
                usesManualOverride: value,
                weekday: config.weekday,
                hour: config.hour,
                minute: config.minute
            )
        }
    }

    func weeklyResetTimeDate(for email: String?) -> Date {
        let config = configuration(for: email)
        var components = DateComponents()
        components.hour = config.hour
        components.minute = config.minute
        return Calendar.current.date(from: components) ?? Date()
    }

    func setWeeklyResetTimeDate(_ date: Date, for email: String?) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        updateConfiguration(for: email) { config in
            config = WeeklyResetConfiguration(
                usesManualOverride: config.usesManualOverride,
                weekday: config.weekday,
                hour: components.hour ?? 9,
                minute: components.minute ?? 0
            )
        }
    }

    func setWeeklyResetWeekday(_ weekday: Int, for email: String?) {
        updateConfiguration(for: email) { config in
            config = WeeklyResetConfiguration(
                usesManualOverride: config.usesManualOverride,
                weekday: weekday,
                hour: config.hour,
                minute: config.minute
            )
        }
    }

    private func startUsageRefreshLoop() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshCurrentUsageIfNeeded(force: true)
            }
        }
        refreshTimer?.tolerance = 15
    }

    private func refreshCurrentUsageIfNeeded(force: Bool) async {
        guard let currentEmail else { return }
        let normalized = Self.normalizedEmailKey(currentEmail)
        if !force,
           let snapshot = usageByEmail[normalized],
           Date().timeIntervalSince(snapshot.updatedAt) < 300
        {
            return
        }

        do {
            if let usageSnapshot = try await service.fetchCurrentClaudeUsage() {
                storeUsageSnapshot(usageSnapshot)
                if !isBusy {
                    statusMessage = "Usage updated for \(usageSnapshot.email)"
                }
            }
        } catch {
            if !isBusy {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshCodexUsageIfNeeded(force: Bool) async {
        if !force,
           let codexSnapshot,
           Date().timeIntervalSince(codexSnapshot.updatedAt) < 300
        {
            return
        }

        do {
            let snapshot = try await service.fetchCodexUsage()
            codexSnapshot = snapshot
            CodexUsageSnapshotStore.save(snapshot)
        } catch {
            if !isBusy {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func storeUsageSnapshot(_ usageSnapshot: ClaudeUsageSnapshot) {
        usageByEmail[Self.normalizedEmailKey(usageSnapshot.email)] = usageSnapshot
        ClaudeUsageSnapshotStore.save(usageByEmail)
    }

    private func updateConfiguration(for email: String?, mutate: (inout WeeklyResetConfiguration) -> Void) {
        guard let email else { return }
        let key = Self.normalizedEmailKey(email)
        var config = weeklyResetOverridesByEmail[key] ?? Self.defaultWeeklyResetConfiguration
        mutate(&config)
        weeklyResetOverridesByEmail[key] = config
        WeeklyResetOverrideStore.save(weeklyResetOverridesByEmail)
        objectWillChange.send()
    }

    private static func normalizedEmailKey(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let defaultWeeklyResetConfiguration = WeeklyResetConfiguration(
        usesManualOverride: false,
        weekday: 2,
        hour: 9,
        minute: 0
    )

    private func runOperation(successMessage: String, task: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = "Working..."

        Task {
            do {
                try await task()
                refresh()
                statusMessage = successMessage
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Action failed"
            }
            isBusy = false
        }
    }
}

struct MenuBarContentView: View {
    @ObservedObject var store: AccountStore
    @State private var selectedTab: AppTab = .claude

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color.clear,
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 16) {
                tabPicker

                if selectedTab == .claude {
                    VStack(alignment: .leading, spacing: 16) {
                        claudeOverviewCard
                        accountsSection
                        actionsSection
                        footer
                    }
                }
                else if selectedTab == .codex {
                    VStack(alignment: .leading, spacing: 16) {
                        codexOverviewCard
                        codexSection
                        codexFooter
                    }
                }
                else {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHeader
                        settingsSection
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 10) {
            tabButton(.claude, title: "Claude", systemImage: "person.2.fill")
            tabButton(.codex, title: "Codex", systemImage: "terminal")
            tabButton(.settings, title: "Settings", systemImage: "slider.horizontal.3")
        }
    }

    private func tabButton(_ tab: AppTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.82))
        }
        .buttonStyle(.plain)
    }

    private var claudeOverviewCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude Accounts")
                            .font(.title3.weight(.bold))

                        Text(claudeOverviewSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusPill(title: "Claude", tint: .accentColor)
                }

                overviewMetric(
                    title: "Current Claude login",
                    value: store.currentEmail ?? "Not connected",
                    systemImage: "sparkles.rectangle.stack"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.statusMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.errorMessage == nil ? Color.primary.opacity(0.85) : Color.red)

                    if let errorMessage = store.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var codexOverviewCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codex Usage")
                            .font(.title3.weight(.bold))

                        Text("Track your Codex weekly and session usage in a dedicated view.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusPill(title: "Codex", tint: .orange)
                }

                overviewMetric(
                    title: "Connected Codex account",
                    value: store.codexSnapshot?.email ?? "Not connected",
                    systemImage: "terminal"
                )

                if let codexSnapshot = store.codexSnapshot {
                    Text(codexSnapshot.relativeUpdatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var claudeOverviewSubtitle: String {
        if let currentEmail = store.currentEmail {
            return "Current login: \(currentEmail)"
        }
        return "Manage your Claude accounts and switch between them quickly."
    }

    private func overviewMetric(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title3.weight(.bold))
            Text("Behavior, menu bar chart source, and weekly reset overrides per account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(
                        title: "General",
                        subtitle: "Choose what the menu bar highlights and how switching behaves."
                    )

                    Toggle(isOn: $store.autoRestartClaudeAfterSwitch) {
                        Text("Restart Claude Code automatically after switch")
                            .font(.footnote)
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu bar chart")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Menu bar chart", selection: Binding(
                            get: { store.menuBarUsageSource },
                            set: { store.menuBarUsageSource = $0 }
                        )) {
                            ForEach(MenuBarUsageSource.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(
                        title: "Weekly Reset Override",
                        subtitle: "Use automatic reset from Claude when available, or set a manual fallback per account."
                    )

                    Picker("Account", selection: Binding(
                        get: { store.settingsAccountEmail ?? "" },
                        set: { newValue in
                            store.settingsAccountEmail = newValue.isEmpty ? nil : newValue
                        }
                    )) {
                        ForEach(store.accounts) { account in
                            Text(account.email).tag(account.email)
                        }
                    }
                    .disabled(store.accounts.isEmpty)

                    Toggle(
                        isOn: Binding(
                            get: { store.configuration(for: store.settingsAccountEmail).usesManualOverride },
                            set: { store.setWeeklyResetManualOverride($0, for: store.settingsAccountEmail) }
                        )
                    ) {
                        Text("Override weekly reset manually for selected account")
                            .font(.footnote)
                    }
                    .toggleStyle(.switch)
                    .disabled(store.settingsAccountEmail == nil)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reset day")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("Reset day", selection: Binding(
                                get: { store.configuration(for: store.settingsAccountEmail).weekday },
                                set: { store.setWeeklyResetWeekday($0, for: store.settingsAccountEmail) }
                            )) {
                                ForEach(Array(weekdayOptions.enumerated()), id: \.offset) { index, title in
                                    Text(title).tag(index + 1)
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reset time")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            DatePicker(
                                "Reset time",
                                selection: Binding(
                                    get: { store.weeklyResetTimeDate(for: store.settingsAccountEmail) },
                                    set: { store.setWeeklyResetTimeDate($0, for: store.settingsAccountEmail) }
                                ),
                                displayedComponents: [.hourAndMinute]
                            )
                            .labelsHidden()
                        }
                    }
                    .disabled(store.settingsAccountEmail == nil)

                    Text("Automatic reset comes from Claude usage data when available. The selected account can override it manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var weekdayOptions: [String] {
        Calendar.current.weekdaySymbols
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Managed Accounts",
                subtitle: store.accounts.isEmpty ? "Add your first Claude account after signing in." : "\(store.accounts.count) saved account\(store.accounts.count == 1 ? "" : "s") ready to switch."
            )

            if store.accounts.isEmpty {
                SurfaceCard {
                    Text("No saved accounts yet. Log into Claude Code with the account you want, then use Add Current Account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.accounts) { account in
                            accountRow(account)
                        }
                    }
                }
                .frame(height: accountListHeight)
            }
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Codex",
                subtitle: "Track Codex weekly usage here even though switching stays Claude-only."
            )

            if let codexSnapshot = store.codexSnapshot {
                CodexAccountCard(snapshot: codexSnapshot)
            } else {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Codex account connected yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Open Codex") {
                            store.connectCodex()
                        }
                        .disabled(store.isBusy)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Quick Actions",
                    subtitle: "Save the current Claude login, refresh usage, or connect another account through the browser."
                )

                HStack(spacing: 10) {
                    Button {
                        store.addCurrentAccount()
                    } label: {
                        if store.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Add Current Account", systemImage: "plus.circle")
                        }
                    }
                    .disabled(store.isBusy || !store.canAddCurrentAccount)

                    Button {
                        store.refresh(forceUsageRefresh: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusy)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect another account")
                        .font(.footnote.weight(.semibold))

                    Text("Log out of the current Claude account, start browser login, then return here. The new account is saved automatically when login finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Log Out") {
                            store.logoutClaude()
                        }
                        .disabled(store.isBusy || store.currentEmail == nil)

                        Button("Browser Login") {
                            store.loginClaudeInBrowser()
                        }
                        .disabled(store.isBusy)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var accountListHeight: CGFloat {
        let rowHeight: CGFloat = 142
        let padding: CGFloat = 8
        let desired = CGFloat(store.accounts.count) * rowHeight + padding
        return min(max(desired, 110), 420)
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(account.email)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Text("Account \(account.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if account.isActive {
                            statusPill(title: "Active", tint: .green)
                        }
                    }
                }

                Spacer()

                Button(account.isActive ? "Current" : "Switch") {
                    store.switchToAccount(account)
                }
                .disabled(store.isBusy || account.isActive)
                .controlSize(.large)
            }

            if let snapshot = store.usageSnapshot(for: account.email) {
                WeeklyUsageSummaryView(
                    snapshot: snapshot,
                    configuration: store.configuration(for: account.email)
                )
            } else {
                Text("Usage appears after this account becomes active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(account.isActive ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(account.isActive ? Color.accentColor.opacity(0.20) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Text("Restart Claude Code after switching.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.top, 4)
    }

    private var codexFooter: some View {
        HStack {
            Text("Codex usage refreshes automatically every 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.top, 4)
    }

    private func statusPill(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct WeeklyUsageSummaryView: View {
    let snapshot: ClaudeUsageSnapshot
    let configuration: WeeklyResetConfiguration

    private var tint: Color {
        switch snapshot.paceStatus(using: configuration) {
        case .onPace:
            return .green
        case .warning:
            return .yellow
        case .over:
            return .red
        }
    }

    private var paceMarkerPosition: CGFloat {
        CGFloat(min(max(snapshot.weeklyIdealUtilization(using: configuration), 0), 1))
    }

    private var idealLineText: String {
        if !snapshot.weeklyWindowHasStarted && !configuration.usesManualOverride {
            return "Ideal now: waits for first weekly message"
        }
        return "Ideal now: \(snapshot.weeklyIdealPercentText(using: configuration)) • \(snapshot.paceLabel(using: configuration))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("All models weekly usage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(snapshot.weeklyPercentText) used")
                    .font(.caption.weight(.semibold))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint)
                        .frame(width: max(8, geometry.size.width * snapshot.weeklyUtilization), height: 10)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 4, height: 16)
                        .overlay(
                            Capsule()
                                .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                        )
                        .offset(x: max(0, min(geometry.size.width - 4, geometry.size.width * paceMarkerPosition - 2)))
                }
            }
            .frame(height: 16)

            Text(idealLineText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Reset: \(snapshot.weeklyResetText(using: configuration))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(snapshot.relativeUpdatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct CodexAccountCard: View {
    let snapshot: CodexUsageSnapshot

    private var tint: Color {
        switch snapshot.paceStatus {
        case .onPace:
            return .green
        case .warning:
            return .yellow
        case .over:
            return .red
        }
    }

    private var paceMarkerPosition: CGFloat {
        CGFloat(min(max(snapshot.weeklyIdealUtilization, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.email)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                    Text((snapshot.planType ?? "codex").uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Codex")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Weekly usage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snapshot.weeklyPercentText) used")
                        .font(.caption.weight(.semibold))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 10)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tint)
                            .frame(width: max(8, geometry.size.width * snapshot.weeklyUtilization), height: 10)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: 4, height: 16)
                            .overlay(
                                Capsule()
                                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                            )
                            .offset(x: max(0, min(geometry.size.width - 4, geometry.size.width * paceMarkerPosition - 2)))
                    }
                }
                .frame(height: 16)

                Text("Ideal now: \(snapshot.weeklyIdealPercentText) • \(snapshot.paceLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Reset: \(snapshot.weeklyResetText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Session: \(snapshot.sessionPercentText) used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(snapshot.relativeUpdatedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.14), lineWidth: 1)
        )
    }
}

struct MenuBarUsageIconView: View {
    let snapshot: ClaudeUsageSnapshot?
    let configuration: WeeklyResetConfiguration

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.makeImage(snapshot: snapshot, configuration: configuration))
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 18, height: 18)
        .accessibilityLabel(snapshot.map { "Weekly usage \($0.weeklyPercentText)" } ?? "Claude Switch")
    }
}

struct CodexMenuBarUsageIconView: View {
    let snapshot: CodexUsageSnapshot?

    var body: some View {
        Image(nsImage: CodexMenuBarIconRenderer.makeImage(snapshot: snapshot))
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 18, height: 18)
            .accessibilityLabel(snapshot.map { "Codex weekly usage \($0.weeklyPercentText)" } ?? "Codex usage")
    }
}

enum CodexMenuBarIconRenderer {
    static func makeImage(snapshot: CodexUsageSnapshot?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 6.5
        let lineWidth: CGFloat = 2.6

        let ringPath = NSBezierPath()
        ringPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        ringPath.lineWidth = lineWidth
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
        ringPath.stroke()

        if let snapshot {
            let progress = max(0.04, min(snapshot.weeklyUtilization, 1))
            let startAngle: CGFloat = 90
            let endAngle = startAngle - (360 * progress)
            let progressPath = NSBezierPath()
            progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            progressPath.lineWidth = lineWidth
            progressPath.lineCapStyle = .round
            NSColor.systemOrange.setStroke()
            progressPath.stroke()
        } else {
            let fallback = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Codex usage")
            fallback?.size = NSSize(width: 14, height: 14)
            fallback?.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
        }

        let dotRect = NSRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        NSColor.tertiaryLabelColor.setFill()
        dotPath.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

enum MenuBarIconRenderer {
    static func makeImage(snapshot: ClaudeUsageSnapshot?, configuration: WeeklyResetConfiguration) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 6.5
        let lineWidth: CGFloat = 2.6

        let ringPath = NSBezierPath()
        ringPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        ringPath.lineWidth = lineWidth
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
        ringPath.stroke()

        if let snapshot {
            let progress = max(0.04, min(snapshot.weeklyUtilization, 1))
            let startAngle: CGFloat = 90
            let endAngle = startAngle - (360 * progress)
            let progressPath = NSBezierPath()
            progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            progressPath.lineWidth = lineWidth
            progressPath.lineCapStyle = .round
            color(for: snapshot.paceStatus(using: configuration)).setStroke()
            progressPath.stroke()
        } else {
            let fallback = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Claude Switch")
                ?? NSImage(systemSymbolName: "asterisk.circle", accessibilityDescription: "Claude Switch")
            fallback?.size = NSSize(width: 14, height: 14)
            fallback?.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
        }

        let dotRect = NSRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        NSColor.tertiaryLabelColor.setFill()
        dotPath.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func color(for status: UsagePaceStatus) -> NSColor {
        switch status {
        case .onPace:
            return .labelColor
        case .warning:
            return .systemYellow
        case .over:
            return .systemRed
        }
    }
}

struct ManagedAccount: Identifiable, Equatable {
    let number: Int
    let email: String
    let isActive: Bool

    var id: Int { number }
}

struct Snapshot {
    let accounts: [ManagedAccount]
    let currentEmail: String?
    let managedCurrentAccountNumber: Int?
}

struct SequenceState: Decodable {
    let activeAccountNumber: Int?
    let sequence: [Int]
    let accounts: [String: StoredAccount]
}

struct StoredAccount: Decodable {
    let email: String
}

struct ClaudeConfig: Decodable {
    let oauthAccount: OAuthAccount?
}

struct OAuthAccount: Decodable {
    let emailAddress: String?
}

struct CommandResult: Sendable {
    let output: String
    let exitCode: Int32
}

enum ClaudeSwitcherError: LocalizedError {
    case missingScript(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingScript(let path):
            return "ccswitch script not found at \(path)"
        case .commandFailed(let message):
            return message
        }
    }
}

struct ClaudeSwitcherService {
    private let fileManager = FileManager.default
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    private var scriptPath: String {
        homeDirectory.appendingPathComponent(".local/share/cc-account-switcher/ccswitch.sh").path
    }

    private var sequenceURL: URL {
        homeDirectory.appendingPathComponent(".claude-switch-backup/sequence.json")
    }

    private var claudeExecutablePath: String {
        let preferred = "/opt/homebrew/bin/claude"
        if fileManager.isExecutableFile(atPath: preferred) {
            return preferred
        }
        return "/usr/bin/env"
    }

    private var primaryConfigURL: URL {
        homeDirectory.appendingPathComponent(".claude/.claude.json")
    }

    private var fallbackConfigURL: URL {
        homeDirectory.appendingPathComponent(".claude.json")
    }

    private var claudeDesktopURL: URL {
        URL(fileURLWithPath: "/Applications/Claude.app")
    }

    func loadSnapshot() throws -> Snapshot {
        let currentEmail = try loadCurrentEmail()
        let state = try loadSequenceState()

        let managedCurrentAccountNumber = currentEmail.flatMap { email in
            state?.accounts.first { $0.value.email == email }.flatMap { Int($0.key) }
        }

        let accounts: [ManagedAccount] = state.map { state in
            state.sequence.compactMap { number in
                guard let stored = state.accounts[String(number)] else {
                    return nil
                }
                return ManagedAccount(
                    number: number,
                    email: stored.email,
                    isActive: managedCurrentAccountNumber == number
                )
            }
        } ?? []

        return Snapshot(
            accounts: accounts,
            currentEmail: currentEmail,
            managedCurrentAccountNumber: managedCurrentAccountNumber
        )
    }

    func runCCSwitch(arguments: [String]) async throws -> CommandResult {
        let scriptPath = scriptPath
        guard fileManager.isReadableFile(atPath: scriptPath) else {
            throw ClaudeSwitcherError.missingScript(scriptPath)
        }

        return try await Task.detached(priority: .userInitiated) {
            try runCommandSync(
                executablePath: resolvedBashPath(),
                arguments: [scriptPath] + arguments
            )
        }.value
    }

    func runClaudeAuth(arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            if claudeExecutablePathStatic() == "/usr/bin/env" {
                return try runCommandSync(
                    executablePath: "/usr/bin/env",
                    arguments: ["claude"] + arguments
                )
            }

            return try runCommandSync(
                executablePath: claudeExecutablePathStatic(),
                arguments: arguments
            )
        }.value
    }

    func quitClaudeDesktopIfRunning() async {
        await Task.detached(priority: .userInitiated) {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            guard !runningApps.isEmpty else { return }

            for app in runningApps {
                _ = app.terminate()
            }

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
                if stillRunning.isEmpty {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                _ = app.forceTerminate()
            }
        }.value
    }

    func launchClaudeDesktop() async throws {
        let appURL = claudeDesktopURL
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                throw ClaudeSwitcherError.commandFailed("Claude desktop app not found at \(appURL.path)")
            }

            _ = try runCommandSync(
                executablePath: "/usr/bin/open",
                arguments: [appURL.path]
            )
        }.value
    }

    private func loadSequenceState() throws -> SequenceState? {
        guard fileManager.fileExists(atPath: sequenceURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: sequenceURL)
        return try JSONDecoder().decode(SequenceState.self, from: data)
    }

    func loadCurrentEmail() throws -> String? {
        let configURL = resolvedConfigURL()
        guard fileManager.fileExists(atPath: configURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ClaudeConfig.self, from: data)
        return config.oauthAccount?.emailAddress
    }

    private func resolvedConfigURL() -> URL {
        if fileManager.fileExists(atPath: primaryConfigURL.path) {
            return primaryConfigURL
        }
        return fallbackConfigURL
    }
}

private func resolvedBashPath() -> String {
    let preferred = "/opt/homebrew/bin/bash"
    if FileManager.default.isExecutableFile(atPath: preferred) {
        return preferred
    }
    return "/bin/bash"
}

private func claudeExecutablePathStatic() -> String {
    let preferred = "/opt/homebrew/bin/claude"
    if FileManager.default.isExecutableFile(atPath: preferred) {
        return preferred
    }
    return "/usr/bin/env"
}

func runCommandSync(executablePath: String, arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let username = NSUserName()
    process.environment = ProcessInfo.processInfo.environment.merging([
        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": username,
        "LOGNAME": username,
        "SHELL": "/bin/zsh"
    ]) { _, new in new }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let combined = [stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

    let result = CommandResult(output: combined, exitCode: process.terminationStatus)
    if result.exitCode != 0 {
        throw ClaudeSwitcherError.commandFailed(combined.isEmpty ? "ccswitch exited with code \(result.exitCode)" : combined)
    }

    return result
}
