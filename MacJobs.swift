import Foundation
import SwiftUI

@main
struct MacJobsApp: App {
    var body: some Scene {
        WindowGroup("MacJobs") {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

struct LaunchSource: Identifiable, Hashable {
    let id: String
    let title: String
    let directory: String
}

enum JobStatus: String, Hashable {
    case active
    case paused
    case unknown

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .unknown:
            return "Unknown"
        }
    }

    var iconName: String {
        switch self {
        case .active:
            return "play.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

enum JobLevel: String, Hashable {
    case user
    case system

    var title: String {
        switch self {
        case .user:
            return "User"
        case .system:
            return "System"
        }
    }
}

struct DashboardSummary {
    let activeUserJobs: Int
    let activeSystemJobs: Int
    let recentJobs: [LaunchJob]
}

struct LaunchJob: Identifiable, Hashable {
    let id: String
    let displayName: String
    let label: String
    let sourceTitle: String
    let plistPath: String
    let schedule: String
    let runAtLoad: Bool
    let command: String
    let status: JobStatus
    let level: JobLevel
    let lastRunAt: Date?
}

final class JobsStore: ObservableObject {
    @Published var jobs: [LaunchJob] = []
    @Published var includeSystem: Bool = false
    @Published var searchText: String = ""
    @Published var lastRefresh: Date = Date()
    @Published var dashboard: DashboardSummary = .init(activeUserJobs: 0, activeSystemJobs: 0, recentJobs: [])

    private let fileManager = FileManager.default

    func refresh() {
        jobs = loadRecurringJobs(includeSystem: includeSystem)
        dashboard = buildDashboard()
        lastRefresh = Date()
    }

    func deleteJob(_ job: LaunchJob) -> String? {
        if job.plistPath.hasPrefix("/System/Library/") {
            return "System-managed jobs in /System/Library cannot be removed from user apps."
        }

        if let unloadError = unloadJob(job) {
            return unloadError
        }

        do {
            try fileManager.removeItem(atPath: job.plistPath)
            refresh()
            return nil
        } catch {
            let message = error.localizedDescription
            if isPermissionRelated(message) {
                let delete = runPrivilegedShell("/bin/rm -f \(shellEscape(job.plistPath))")
                if delete.exitCode == 0 {
                    refresh()
                    return nil
                }

                let output = [delete.stdout, delete.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    return "Could not delete plist with admin privileges: \(output)"
                }
                return "Could not delete plist with admin privileges."
            }

            return message
        }
    }

    func pauseJob(_ job: LaunchJob) -> String? {
        if let unloadError = unloadJob(job) {
            return unloadError
        }
        refresh()
        return nil
    }

    func resumeJob(_ job: LaunchJob) -> String? {
        if let loadError = loadJob(job) {
            return loadError
        }
        refresh()
        return nil
    }

    private func unloadJob(_ job: LaunchJob) -> String? {
        let uid = String(getuid())
        let isDaemon = job.plistPath.contains("/LaunchDaemons/")

        let attempts: [[String]]
        if isDaemon {
            attempts = [
                ["bootout", "system", job.plistPath],
                ["bootout", "system/\(job.label)"]
            ]
        } else {
            attempts = [
                ["bootout", "gui/\(uid)", job.plistPath],
                ["bootout", "gui/\(uid)/\(job.label)"],
                ["bootout", "user/\(uid)", job.plistPath],
                ["bootout", "user/\(uid)/\(job.label)"]
            ]
        }

        var lastError = ""
        var sawPermissionError = false
        for args in attempts {
            let result = runLaunchctl(args)
            if result.exitCode == 0 {
                return nil
            }

            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if output.localizedCaseInsensitiveContains("No such process") ||
                output.localizedCaseInsensitiveContains("Could not find service") ||
                output.localizedCaseInsensitiveContains("service not found") {
                return nil
            }

            if isPermissionRelated(output) {
                sawPermissionError = true
            }

            if !output.isEmpty {
                lastError = output
            }
        }

        if sawPermissionError, tryPrivilegedUnload(job) {
            return nil
        }

        if lastError.isEmpty {
            if isDaemon {
                return "Could not unload daemon before deletion. Try from Terminal with sudo: launchctl bootout system \"\(job.plistPath)\""
            }
            return "Could not unload job before deletion. Try from Terminal: launchctl bootout gui/\(uid) \"\(job.plistPath)\""
        }

        return "Could not unload job before deletion: \(lastError)"
    }

    private func loadJob(_ job: LaunchJob) -> String? {
        let uid = String(getuid())
        let isDaemon = job.plistPath.contains("/LaunchDaemons/")

        let attempts: [[String]]
        if isDaemon {
            attempts = [
                ["bootstrap", "system", job.plistPath]
            ]
        } else {
            attempts = [
                ["bootstrap", "gui/\(uid)", job.plistPath],
                ["bootstrap", "user/\(uid)", job.plistPath]
            ]
        }

        var lastError = ""
        var sawPermissionError = false
        for args in attempts {
            let result = runLaunchctl(args)
            if result.exitCode == 0 {
                return nil
            }

            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if output.localizedCaseInsensitiveContains("service already loaded") ||
                output.localizedCaseInsensitiveContains("already bootstrapped") {
                return nil
            }

            if isPermissionRelated(output) {
                sawPermissionError = true
            }

            if !output.isEmpty {
                lastError = output
            }
        }

        if sawPermissionError, tryPrivilegedLoad(job) {
            return nil
        }

        if lastError.isEmpty {
            if isDaemon {
                return "Could not load daemon. Try from Terminal with sudo: launchctl bootstrap system \"\(job.plistPath)\""
            }
            return "Could not load job. Try from Terminal: launchctl bootstrap gui/\(uid) \"\(job.plistPath)\""
        }

        return "Could not load job: \(lastError)"
    }

    private func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func tryPrivilegedUnload(_ job: LaunchJob) -> Bool {
        let uid = String(getuid())
        let isDaemon = job.plistPath.contains("/LaunchDaemons/")
        let commands: [String]

        if isDaemon {
            commands = [
                "/bin/launchctl bootout system \(shellEscape(job.plistPath))",
                "/bin/launchctl bootout system/\(shellEscape(job.label))"
            ]
        } else {
            commands = [
                "/bin/launchctl bootout gui/\(uid) \(shellEscape(job.plistPath))",
                "/bin/launchctl bootout gui/\(uid)/\(shellEscape(job.label))",
                "/bin/launchctl bootout user/\(uid) \(shellEscape(job.plistPath))",
                "/bin/launchctl bootout user/\(uid)/\(shellEscape(job.label))"
            ]
        }

        for command in commands {
            let result = runPrivilegedShell(command)
            if result.exitCode == 0 {
                return true
            }

            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if output.localizedCaseInsensitiveContains("No such process") ||
                output.localizedCaseInsensitiveContains("Could not find service") ||
                output.localizedCaseInsensitiveContains("service not found") {
                return true
            }
        }

        return false
    }

    private func tryPrivilegedLoad(_ job: LaunchJob) -> Bool {
        let uid = String(getuid())
        let isDaemon = job.plistPath.contains("/LaunchDaemons/")
        let commands: [String]

        if isDaemon {
            commands = [
                "/bin/launchctl bootstrap system \(shellEscape(job.plistPath))"
            ]
        } else {
            commands = [
                "/bin/launchctl bootstrap gui/\(uid) \(shellEscape(job.plistPath))",
                "/bin/launchctl bootstrap user/\(uid) \(shellEscape(job.plistPath))"
            ]
        }

        for command in commands {
            let result = runPrivilegedShell(command)
            if result.exitCode == 0 {
                return true
            }

            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if output.localizedCaseInsensitiveContains("service already loaded") ||
                output.localizedCaseInsensitiveContains("already bootstrapped") {
                return true
            }
        }

        return false
    }

    private func runPrivilegedShell(_ command: String) -> (exitCode: Int32, stdout: String, stderr: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func isPermissionRelated(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("operation not permitted") ||
            lower.contains("permission denied") ||
            lower.contains("not permitted") ||
            lower.contains("you must be root") ||
            lower.contains("not privileged") ||
            lower.contains("administrator privileges")
    }

    private func statusForJob(label: String, plistPath: String) -> JobStatus {
        let uid = String(getuid())
        let isDaemon = plistPath.contains("/LaunchDaemons/")

        let targets: [String]
        if isDaemon {
            targets = ["system/\(label)"]
        } else {
            targets = ["gui/\(uid)/\(label)", "user/\(uid)/\(label)"]
        }

        var unknownHit = false
        for target in targets {
            let result = runLaunchctl(["print", target])
            if result.exitCode == 0 {
                return .active
            }

            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if output.localizedCaseInsensitiveContains("Could not find service") ||
                output.localizedCaseInsensitiveContains("service not found") ||
                output.localizedCaseInsensitiveContains("No such process") {
                continue
            }

            if output.localizedCaseInsensitiveContains("Operation not permitted") ||
                output.localizedCaseInsensitiveContains("not permitted") ||
                output.localizedCaseInsensitiveContains("permission denied") {
                unknownHit = true
                continue
            }

            if !output.isEmpty {
                unknownHit = true
            }
        }

        return unknownHit ? .unknown : .paused
    }

    var filteredJobs: [LaunchJob] {
        let base = jobs.sorted { lhs, rhs in
            if lhs.sourceTitle != rhs.sourceTitle { return lhs.sourceTitle < rhs.sourceTitle }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            if lhs.label != rhs.label { return lhs.label < rhs.label }
            return lhs.plistPath < rhs.plistPath
        }

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }

        let query = searchText.lowercased()
        return base.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.label.lowercased().contains(query) ||
            $0.sourceTitle.lowercased().contains(query) ||
            $0.plistPath.lowercased().contains(query) ||
            $0.schedule.lowercased().contains(query) ||
            $0.command.lowercased().contains(query) ||
            $0.status.title.lowercased().contains(query)
        }
    }

    private func loadRecurringJobs(includeSystem: Bool) -> [LaunchJob] {
        var sources: [LaunchSource] = [
            .init(id: "user-agents", title: "User LaunchAgents", directory: "~/Library/LaunchAgents"),
            .init(id: "local-agents", title: "Local LaunchAgents", directory: "/Library/LaunchAgents"),
            .init(id: "local-daemons", title: "Local LaunchDaemons", directory: "/Library/LaunchDaemons")
        ]

        if includeSystem {
            sources += [
                .init(id: "system-agents", title: "System LaunchAgents", directory: "/System/Library/LaunchAgents"),
                .init(id: "system-daemons", title: "System LaunchDaemons", directory: "/System/Library/LaunchDaemons")
            ]
        }

        var results: [LaunchJob] = []

        for source in sources {
            let resolvedPath = NSString(string: source.directory).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)

            guard let items = try? fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in items where item.pathExtension == "plist" {
                guard
                    let dict = NSDictionary(contentsOf: item) as? [String: Any],
                    let schedule = scheduleDescription(for: dict)
                else {
                    continue
                }

                let label = (dict["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayLabel = (label?.isEmpty == false) ? label! : item.deletingPathExtension().lastPathComponent
                let friendlyName = friendlyName(for: displayLabel)
                let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
                let command = commandDescription(for: dict)
                let status = statusForJob(label: displayLabel, plistPath: item.path)
                let level: JobLevel = source.id.hasPrefix("system-") ? .system : .user
                let lastRunAt = mostRecentLogDate(for: dict)

                results.append(
                    LaunchJob(
                        id: item.path,
                        displayName: friendlyName,
                        label: displayLabel,
                        sourceTitle: source.title,
                        plistPath: item.path,
                        schedule: schedule,
                        runAtLoad: runAtLoad,
                        command: command,
                        status: status,
                        level: level,
                        lastRunAt: lastRunAt
                    )
                )
            }
        }

        return results
    }

    private func buildDashboard() -> DashboardSummary {
        let allJobs = loadRecurringJobs(includeSystem: true)

        let activeUserJobs = allJobs.filter { $0.level == .user && $0.status == .active }.count
        let activeSystemJobs = allJobs.filter { $0.level == .system && $0.status == .active }.count

        let recentJobs = allJobs
            .filter { $0.lastRunAt != nil }
            .sorted { lhs, rhs in
                guard let l = lhs.lastRunAt, let r = rhs.lastRunAt else { return false }
                return l > r
            }
            .prefix(5)

        return DashboardSummary(
            activeUserJobs: activeUserJobs,
            activeSystemJobs: activeSystemJobs,
            recentJobs: Array(recentJobs)
        )
    }

    private func scheduleDescription(for plist: [String: Any]) -> String? {
        var chunks: [String] = []

        if let seconds = plist["StartInterval"] as? Int, seconds > 0 {
            chunks.append(formatInterval(seconds: seconds))
        }

        if let calendar = plist["StartCalendarInterval"] {
            let formatted = formatCalendarSchedule(calendar)
            if !formatted.isEmpty {
                chunks.append(formatted)
            }
        }

        if chunks.isEmpty {
            return nil
        }

        return chunks.joined(separator: " | ")
    }

    private func formatInterval(seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 1 ? "Every day" : "Every \(days) days"
        }

        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }

        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        }

        return "Every \(seconds) seconds"
    }

    private func formatCalendarSchedule(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            return formatCalendarEntry(dict)
        }

        if let entries = value as? [[String: Any]] {
            let compact = entries.prefix(3).map { formatCalendarEntry($0) }.filter { !$0.isEmpty }
            if entries.count > 3 {
                return "\(compact.joined(separator: " ; ")) ; +\(entries.count - 3) more"
            }
            return compact.joined(separator: " ; ")
        }

        return "Calendar schedule"
    }

    private func formatCalendarEntry(_ entry: [String: Any]) -> String {
        let month = intValue(entry["Month"])
        let day = intValue(entry["Day"])
        let weekday = intValue(entry["Weekday"])
        let hour = intValue(entry["Hour"])
        let minute = intValue(entry["Minute"])

        var dateBits: [String] = []

        if let month {
            dateBits.append("month \(month)")
        }

        if let day {
            dateBits.append("day \(day)")
        }

        if let weekday {
            dateBits.append("weekday \(weekday)")
        }

        let time: String
        switch (hour, minute) {
        case let (h?, m?):
            time = String(format: "%02d:%02d", h, m)
        case let (h?, nil):
            time = String(format: "%02d:00", h)
        case let (nil, m?):
            time = String(format: "minute %02d", m)
        default:
            time = "unspecified time"
        }

        if dateBits.isEmpty {
            return "At \(time)"
        }

        return "At \(time) on \(dateBits.joined(separator: ", "))"
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func friendlyName(for rawLabel: String) -> String {
        var value = rawLabel

        if let last = value.split(separator: ".").last {
            value = String(last)
        }

        value = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        var expanded = ""
        var previous: Character?
        for char in value {
            if let previous,
               previous.isLowercase,
               char.isUppercase,
               !expanded.hasSuffix(" ") {
                expanded.append(" ")
            }
            expanded.append(char)
            previous = char
        }

        let collapsed = expanded
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")

        if collapsed.isEmpty {
            return rawLabel
        }

        return collapsed.localizedCapitalized
    }

    private func commandDescription(for plist: [String: Any]) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            return args.map(shellEscape).joined(separator: " ")
        }

        if let program = plist["Program"] as? String, !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return program
        }

        return "No explicit command in plist"
    }

    private func mostRecentLogDate(for plist: [String: Any]) -> Date? {
        let possiblePaths = [plist["StandardOutPath"], plist["StandardErrorPath"]]
            .compactMap { $0 as? String }
            .map { NSString(string: $0).expandingTildeInPath }

        var newest: Date?
        for path in possiblePaths {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else {
                continue
            }

            if newest == nil || modified > newest! {
                newest = modified
            }
        }

        return newest
    }

    private func shellEscape(_ text: String) -> String {
        if text.isEmpty {
            return "''"
        }

        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:@%+=,")
        if text.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return text
        }

        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ContentView: View {
    @StateObject private var store = JobsStore()
    @State private var selection: SidebarSelection? = .overview

    enum SidebarSelection: Hashable {
        case overview
        case job(String)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Overview", systemImage: "rectangle.grid.2x2")
                        .tag(SidebarSelection.overview)
                }

                Section {
                    ForEach(store.filteredJobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.displayName)
                                .font(.headline)
                                .lineLimit(1)

                            Text(job.schedule)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                Image(systemName: job.status.iconName)
                                Text(job.status.title)
                            }
                            .font(.caption)
                            .foregroundStyle(job.status == .active ? .green : (job.status == .paused ? .secondary : .orange))

                            Text("\(job.label) - \(job.sourceTitle)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .tag(SidebarSelection.job(job.id))
                    }
                } header: {
                    Text("Recurring jobs (\(store.filteredJobs.count))")
                }
            }
            .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search name, label, command, path")
            .navigationTitle("MacJobs")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle("Include system", isOn: $store.includeSystem)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("Include /System/Library LaunchAgents and LaunchDaemons")

                    Button {
                        store.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onChange(of: store.includeSystem) { _ in
                store.refresh()
            }
            .onChange(of: store.searchText) { _ in
                if case let .job(selectedID) = selection,
                    !store.filteredJobs.contains(where: { $0.id == selectedID }) {
                    selection = .overview
                }
            }
            .onAppear {
                store.refresh()
                if selection == nil {
                    selection = .overview
                }
            }
        } detail: {
            if case let .job(selectedID) = selection,
                let selected = store.filteredJobs.first(where: { $0.id == selectedID }) {
                JobDetailsView(
                    job: selected,
                    lastRefresh: store.lastRefresh,
                    onPause: { job in
                        store.pauseJob(job)
                    },
                    onResume: { job in
                        store.resumeJob(job)
                    },
                    onDelete: { job in
                        let error = store.deleteJob(job)
                        if error == nil {
                            if case .job(job.id) = selection {
                                selection = .overview
                            }
                        }
                        return error
                    }
                )
            } else {
                DashboardView(summary: store.dashboard, lastRefresh: store.lastRefresh)
            }
        }
    }
}

struct DashboardView: View {
    let summary: DashboardSummary
    let lastRefresh: Date

    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Overview")
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 14) {
                    statCard(title: "Active user jobs", value: String(summary.activeUserJobs), icon: "person.fill")
                    statCard(title: "Active system jobs", value: String(summary.activeSystemJobs), icon: "desktopcomputer")
                }

                Text("5 recent jobs that ran")
                    .font(.headline)

                if summary.recentJobs.isEmpty {
                    Text("No recent run data found from job log files.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.recentJobs) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: job.status.iconName)
                                .foregroundStyle(job.status == .active ? .green : (job.status == .paused ? .secondary : .orange))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.displayName)
                                    .font(.headline)
                                Text("\(job.level.title) | \(job.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let lastRunAt = job.lastRunAt {
                                Text(Self.relativeDateFormatter.localizedString(for: lastRunAt, relativeTo: Date()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Text("Last refresh: \(ContentView.dateFormatter.string(from: lastRefresh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("MacJobs")
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct JobDetailsView: View {
    let job: LaunchJob
    let lastRefresh: Date
    let onPause: (LaunchJob) -> String?
    let onResume: (LaunchJob) -> String?
    let onDelete: (LaunchJob) -> String?

    @State private var pauseErrorMessage = ""
    @State private var showPauseError = false
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(job.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(job.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Group {
                    row("Source", job.sourceTitle)
                    row("Status", job.status.title)
                    row("Level", job.level.title)
                    row("Schedule", job.schedule)
                    row("RunAtLoad", job.runAtLoad ? "Yes" : "No")
                    row("Command", job.command)
                    row("Plist", job.plistPath)
                    row("Last refresh", ContentView.dateFormatter.string(from: lastRefresh))
                }

                HStack {
                    Button {
                        let message: String?
                        if job.status == .active {
                            message = onPause(job)
                        } else {
                            message = onResume(job)
                        }

                        if let message {
                            pauseErrorMessage = message
                            showPauseError = true
                        }
                    } label: {
                        if job.status == .active {
                            Label("Pause job", systemImage: "pause.fill")
                        } else {
                            Label("Resume job", systemImage: "play.fill")
                        }
                    }
                    .help(job.status == .active ? "Unload this job from launchd" : "Load this job into launchd")

                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete job", systemImage: "trash")
                    }
                    .help("Delete this plist file")
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Job details")
        .confirmationDialog(
            "Delete this job plist?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let message = onDelete(job) {
                    deleteErrorMessage = message
                    showDeleteError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unloads the job with launchctl, then removes the plist file from disk.")
        }
        .alert("Delete failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
        .alert("Job action failed", isPresented: $showPauseError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pauseErrorMessage)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .font(.body)
        }
    }
}
