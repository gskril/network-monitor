import AppKit
import SwiftUI

/// In-app setup panel for the two optional capabilities: true hostnames (BPF
/// helper, needs your password) and estimated locations (offline GeoIP data).
struct SetupView: View {
    @EnvironmentObject private var store: FlowStore
    @Environment(\.dismiss) private var dismiss

    @State private var geoInstalled = GeoDataInstaller.isInstalled
    @State private var geoDate = GeoDataInstaller.installedDate
    @State private var downloading = false
    @State private var downloadProgress = 0.0
    @State private var geoError: String?

    @State private var helperInstalled = HostnameHelperInstaller.isInstalled
    @State private var installingHelper = false
    @State private var helperMessage: String?
    @State private var needsRelaunch = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Setup").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hostnamesSection
                    Divider()
                    locationSection
                }
                .padding()
            }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - Hostnames

    private var hostnamesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("True hostnames", systemImage: "checkmark.seal",
                          on: isHostnamesActive)
            Text("Shows the real domain each app requested (e.g. github.com) instead of reverse-DNS guesses, by passively watching DNS responses. Needs one-time access to BPF devices — macOS will ask for your password.")
                .font(.callout).foregroundStyle(.secondary)

            if isHostnamesActive {
                Label("Active — capturing DNS on \(activeInterface ?? "your network")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }

            HStack(spacing: 10) {
                if helperInstalled {
                    Button("Reinstall…") { installHelper() }
                    Button("Remove…", role: .destructive) { uninstallHelper() }
                } else {
                    Button("Enable true hostnames…") { installHelper() }
                        .buttonStyle(.borderedProminent)
                }
                if installingHelper { ProgressView().controlSize(.small) }
            }

            if needsRelaunch {
                HStack(spacing: 8) {
                    Text("Installed. Relaunch to activate.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch now") { relaunch() }
                }
            }
            if let helperMessage {
                Text(helperMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isHostnamesActive: Bool {
        if case .active = store.dnsStatus { return true }
        return false
    }

    private var activeInterface: String? {
        if case .active(let iface) = store.dnsStatus { return iface }
        return nil
    }

    private func installHelper() {
        installingHelper = true
        helperMessage = nil
        Task {
            do {
                try await HostnameHelperInstaller.install()
                helperInstalled = true
                needsRelaunch = !isHostnamesActive
                helperMessage = "If hostnames don't appear after relaunch, log out and back in once so your account joins the Network Monitor BPF group."
            } catch SetupError.cancelled {
                helperMessage = "Cancelled."
            } catch {
                helperMessage = error.localizedDescription
            }
            installingHelper = false
        }
    }

    private func uninstallHelper() {
        installingHelper = true
        Task {
            do {
                try await HostnameHelperInstaller.uninstall()
                helperInstalled = false
                helperMessage = "Removed. Hostnames will use reverse DNS after relaunch."
            } catch SetupError.cancelled {
                helperMessage = "Cancelled."
            } catch {
                helperMessage = error.localizedDescription
            }
            installingHelper = false
        }
    }

    // MARK: - Location data

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Estimated locations", systemImage: "map", on: geoInstalled)
            Text("Enables the Map view and per-connection region. Downloads the free DB-IP City database (~120 MB) for fully offline lookups — nothing about your connections leaves your Mac.")
                .font(.callout).foregroundStyle(.secondary)

            if geoInstalled, let geoDate {
                Label("Installed \(Self.dateFormatter.string(from: geoDate))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }

            if downloading {
                ProgressView(value: downloadProgress) {
                    Text("Downloading… \(Int(downloadProgress * 100))%").font(.caption)
                }
            } else {
                HStack(spacing: 10) {
                    Button(geoInstalled ? "Update database" : "Download location data") { downloadGeo() }
                        .buttonStyle(.borderedProminent)
                    if geoInstalled {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: GeoDataInstaller.dbPath)
                            ])
                        }
                    }
                }
            }

            if let geoError {
                Text(geoError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func downloadGeo() {
        downloading = true
        downloadProgress = 0
        geoError = nil
        Task {
            do {
                try await GeoDataInstaller.download { fraction in downloadProgress = fraction }
                store.reloadGeoIP()
                geoInstalled = true
                geoDate = GeoDataInstaller.installedDate
            } catch {
                geoError = error.localizedDescription
            }
            downloading = false
        }
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String, systemImage: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(on ? .green : .secondary)
            Text(title).font(.headline)
            if on {
                Text("On").font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
    }

    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
