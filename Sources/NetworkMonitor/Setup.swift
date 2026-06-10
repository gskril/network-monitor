import Foundation

enum SetupError: LocalizedError {
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled."
        case .message(let text): text
        }
    }
}

/// Downloads and installs the free DB-IP "IP to City Lite" database natively
/// (no shell script, no privileges). Used by the in-app Setup panel.
enum GeoDataInstaller {
    static let supportDir = NSString(string: "~/Library/Application Support/NetworkMonitor").expandingTildeInPath
    static var dbPath: String { supportDir + "/GeoLite-City.mmdb" }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: dbPath) }

    static var installedDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: dbPath)[.modificationDate] as? Date
    }

    static var installedSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? NSNumber)?.int64Value
    }

    /// Downloads the current (or previous) month's database, decompresses it,
    /// and installs it atomically. `progress` is called with 0...1 on the main
    /// actor.
    static func download(progress: @escaping @MainActor (Double) -> Void) async throws {
        let months = recentMonths()
        var lastError: Error?
        for month in months {
            do {
                try await downloadMonth(month, progress: progress)
                return
            } catch {
                lastError = error
            }
        }
        throw SetupError.message("Could not download the database: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private static func downloadMonth(_ month: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let urlString = "https://download.db-ip.com/free/dbip-city-lite-\(month).mmdb.gz"
        guard let url = URL(string: urlString) else { throw SetupError.message("bad URL") }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SetupError.message("server returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let total = response.expectedContentLength
        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 64 * 1024 * 1024)
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if total > 0 {
                let fraction = Double(data.count) / Double(total)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    await progress(fraction)
                }
            }
        }

        try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let gzPath = supportDir + "/GeoLite-City.mmdb.download.gz"
        try data.write(to: URL(fileURLWithPath: gzPath))
        defer { try? FileManager.default.removeItem(atPath: gzPath) }

        let plainPath = try gunzip(gzPath)
        // Atomic-ish swap into place.
        _ = try? FileManager.default.removeItem(atPath: dbPath)
        try FileManager.default.moveItem(atPath: plainPath, toPath: dbPath)
        await progress(1.0)
    }

    private static func gunzip(_ gzPath: String) throws -> String {
        // gzip -d writes alongside, stripping .gz; -k keeps the source.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-d", "-f", gzPath]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SetupError.message("decompression failed: \(err)")
        }
        return String(gzPath.dropLast(3)) // remove ".gz"
    }

    private static func recentMonths() -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        return (0...1).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: now).map(formatter.string(from:))
        }
    }
}

/// Installs the BPF helper (for true hostnames) by running the bundled script
/// through macOS's standard administrator-authentication prompt.
enum HostnameHelperInstaller {
    private static let helperLabel = "com.gregskril.networkmonitor.chmodbpf"

    /// True once the helper's LaunchDaemon is installed (independent of whether
    /// the current login session has picked up the group yet).
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(helperLabel).plist")
    }

    static func install() async throws {
        try await runScript("install-bpf-helper")
    }

    static func uninstall() async throws {
        try await runScript("uninstall-bpf-helper")
    }

    private static func runScript(_ name: String) async throws {
        guard let scriptURL = locateScript(name) else {
            throw SetupError.message("Couldn't find \(name).sh. Run it from the scripts/ folder manually.")
        }
        let user = NSUserName()
        // Run through `do shell script`, so quote arguments for /bin/sh -c.
        let command = ["/bin/sh", scriptURL.path, user]
            .map(shellEscaped)
            .joined(separator: " ")
        try await runWithAdminPrivileges(command)
    }

    /// Prefers the copy bundled in the app's Resources; falls back to the repo
    /// scripts/ folder for `swift run` during development.
    private static func locateScript(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "sh") {
            return bundled
        }
        let devPath = URL(fileURLWithPath: #filePath) // …/Sources/NetworkMonitor/Setup.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/\(name).sh")
        return FileManager.default.fileExists(atPath: devPath.path) ? devPath : nil
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runWithAdminPrivileges(_ command: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let escaped = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: SetupError.message(error.localizedDescription))
                    return
                }
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if err.contains("-128") || err.localizedCaseInsensitiveContains("cancel") {
                    continuation.resume(throwing: SetupError.cancelled)
                } else {
                    continuation.resume(throwing: SetupError.message(err.isEmpty ? "Installation failed." : err))
                }
            }
        }
    }
}
