import SwiftUI
import MediaPlayer

public struct SettingsView: View {
    @State private var spotifyAuth = SpotifyAuth()
    @State private var appleMusicStatus: MPMediaLibraryAuthorizationStatus =
        MPMediaLibrary.authorizationStatus()
    public var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            List {
                appleMusicSection
                spotifySection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BlueHourBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(StudioJoeColors.accent)
        .task {
            // Refresh profile if already connected.
            if spotifyAuth.isConnected {
                await spotifyAuth.refreshProfile()
            }
        }
    }

    // MARK: - Apple Music

    private var appleMusicSection: some View {
        Section {
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(StudioJoeColors.label2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Music Library")
                        .foregroundStyle(StudioJoeColors.label1)
                    Text(appleMusicStatusText)
                        .font(.footnote)
                        .foregroundStyle(StudioJoeColors.label3)
                }
                Spacer()
            }

            switch appleMusicStatus {
            case .notDetermined:
                Button {
                    MPMediaLibrary.requestAuthorization { status in
                        DispatchQueue.main.async { appleMusicStatus = status }
                    }
                } label: {
                    Label("Grant Library Access", systemImage: "checkmark.seal")
                        .foregroundStyle(StudioJoeColors.accent)
                }
            case .denied, .restricted:
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                        .foregroundStyle(StudioJoeColors.accent)
                }
            case .authorized:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Access granted")
                        .foregroundStyle(StudioJoeColors.label2)
                }
            @unknown default:
                EmptyView()
            }
        } header: {
            Text("Apple Music")
        } footer: {
            Text("Lets the picker browse the songs in your library. Apple Music subscription downloads fall back to system playback with a live mic tap for visualization.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var appleMusicStatusText: String {
        switch appleMusicStatus {
        case .notDetermined: return "Not yet granted"
        case .denied:        return "Denied — change in iOS Settings"
        case .restricted:    return "Restricted by device policy"
        case .authorized:    return "Granted"
        @unknown default:    return "Unknown"
        }
    }

    // MARK: - Spotify

    private var spotifySection: some View {
        Section {
            HStack {
                Image(systemName: "music.note.house")
                    .font(.title3)
                    .foregroundStyle(StudioJoeColors.label2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify")
                        .foregroundStyle(StudioJoeColors.label1)
                    Text(spotifyStatusText)
                        .font(.footnote)
                        .foregroundStyle(StudioJoeColors.label3)
                        .lineLimit(2)
                }
                Spacer()
            }

            if !AppConfig.isSpotifyConfigured {
                Label("SPOTIFY_CLIENT_ID not set in Secrets.xcconfig",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            } else if spotifyAuth.isConnected {
                if let profile = spotifyAuth.profile {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(StudioJoeColors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.display_name ?? profile.id)
                                .foregroundStyle(StudioJoeColors.label1)
                            if let product = profile.product {
                                Text("Plan: \(product)")
                                    .font(.footnote)
                                    .foregroundStyle(StudioJoeColors.label3)
                            }
                        }
                    }
                }
                Button(role: .destructive) {
                    spotifyAuth.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    Task { await spotifyAuth.connect() }
                } label: {
                    HStack {
                        if spotifyAuth.isAuthorizing {
                            ProgressView().tint(StudioJoeColors.accent)
                        }
                        Label(spotifyAuth.isAuthorizing ? "Connecting…" : "Connect Spotify",
                              systemImage: "link")
                            .foregroundStyle(StudioJoeColors.accent)
                    }
                }
                .disabled(spotifyAuth.isAuthorizing)

                if let err = spotifyAuth.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Connects via PKCE and streams 30-second preview clips. Full-track Spotify playback isn't integrated yet.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var spotifyStatusText: String {
        if !AppConfig.isSpotifyConfigured { return "Not configured" }
        if spotifyAuth.isConnected {
            if let name = spotifyAuth.profile?.display_name { return "Signed in as \(name)" }
            return "Connected"
        }
        return "Not connected"
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(StudioJoeColors.label2)
                Spacer()
                Text(appVersion)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StudioJoeColors.label3)
            }
            HStack {
                Text("Build")
                    .foregroundStyle(StudioJoeColors.label2)
                Spacer()
                Text(appBuild)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StudioJoeColors.label3)
            }
        } header: {
            Text("About")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    private var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }
}
