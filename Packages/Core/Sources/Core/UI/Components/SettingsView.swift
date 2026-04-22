import SwiftUI
import MediaPlayer

public struct SettingsView: View {
    @State private var spotifyAuth = SpotifyAuth()
    @State private var appleMusicStatus: MPMediaLibraryAuthorizationStatus =
        MPMediaLibrary.authorizationStatus()
    @ObservedObject var viewModel: VisualizerViewModel
    @ObservedObject var spotifyPlayback: SpotifyPlaybackSource
    public var onDismiss: () -> Void

    public init(viewModel: VisualizerViewModel,
                spotifyPlayback: SpotifyPlaybackSource,
                onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.spotifyPlayback = spotifyPlayback
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            List {
                analysisSection
                appleMusicSection
                spotifySection
                spotifyPlaybackSection
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

    // MARK: - Analysis source

    private var analysisSection: some View {
        Section {
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(StudioJoeColors.label2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefer Spotify Analysis")
                        .foregroundStyle(StudioJoeColors.label1)
                    Text(analysisStatusText)
                        .font(.footnote)
                        .foregroundStyle(StudioJoeColors.label3)
                        .lineLimit(3)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.preferSyntheticAnalysis },
                    set: { viewModel.setPreferSyntheticAnalysis($0) }
                ))
                .labelsHidden()
            }

            HStack {
                Image(systemName: sourceIcon)
                    .foregroundStyle(sourceIconColor)
                Text("Current source: \(sourceLabel)")
                    .font(.footnote)
                    .foregroundStyle(StudioJoeColors.label2)
                Spacer()
            }
        } header: {
            Text("Audio Reactivity")
        } footer: {
            Text("When on, Spotify tracks (and Apple Music tracks with an ISRC match) drive the visualizer from Spotify's pre-computed beat + loudness analysis. Other tracks fall back to live FFT on the audio file — or stay gently animated when there's nothing to tap.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var analysisStatusText: String {
        if !viewModel.preferSyntheticAnalysis {
            return "Off — using live FFT from the audio file"
        }
        return "Spotify tracks use pre-computed analysis; others fall back to tap"
    }

    private var sourceIcon: String {
        switch viewModel.activeAnalysisSource {
        case .synthetic:            return "antenna.radiowaves.left.and.right"
        case .syntheticFromPreview: return "waveform.path"
        case .tap:                  return "waveform"
        }
    }

    private var sourceIconColor: Color {
        switch viewModel.activeAnalysisSource {
        case .synthetic:            return StudioJoeColors.accent
        case .syntheticFromPreview: return StudioJoeColors.label2
        case .tap:                  return StudioJoeColors.label3
        }
    }

    private var sourceLabel: String {
        switch viewModel.activeAnalysisSource {
        case .synthetic:            return "Synthetic (Spotify)"
        case .syntheticFromPreview: return "Synthetic (preview)"
        case .tap:                  return "Live tap"
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
            Text("Lets the picker browse the songs in your library. Subscription downloads play through the system player; visuals react via Spotify analysis when available, or stay gently animated otherwise.")
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

    // MARK: - Spotify Playback (SPTAppRemote)

    private var spotifyPlaybackSection: some View {
        Section {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(StudioJoeColors.label2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify Playback")
                        .foregroundStyle(StudioJoeColors.label1)
                    Text(spotifyPlaybackStatusText)
                        .font(.footnote)
                        .foregroundStyle(StudioJoeColors.label3)
                        .lineLimit(2)
                }
                Spacer()
            }

            if spotifyPlayback.isConnected, let track = spotifyPlayback.currentTrack {
                HStack {
                    Image(systemName: spotifyPlayback.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(StudioJoeColors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.footnote)
                            .foregroundStyle(StudioJoeColors.label1)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.footnote)
                            .foregroundStyle(StudioJoeColors.label3)
                            .lineLimit(1)
                    }
                }
            }

            if spotifyPlayback.isConnected {
                Button(role: .destructive) {
                    spotifyPlayback.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    _ = spotifyPlayback.connect()
                } label: {
                    HStack {
                        if spotifyPlayback.isAuthorizing {
                            ProgressView().tint(StudioJoeColors.accent)
                        }
                        Label(spotifyPlayback.isAuthorizing ? "Opening Spotify…" : "Connect Spotify App",
                              systemImage: "app.connected.to.app.below.fill")
                            .foregroundStyle(StudioJoeColors.accent)
                    }
                }
                .disabled(spotifyPlayback.isAuthorizing)
            }

            if let err = spotifyPlayback.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        } header: {
            Text("Spotify Playback")
        } footer: {
            Text("Plays full tracks via the installed Spotify app. Requires Spotify Premium. Tapping Connect opens Spotify to authorize.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var spotifyPlaybackStatusText: String {
        if spotifyPlayback.isConnected { return "Connected — full-track playback enabled" }
        if spotifyPlayback.isAuthorizing { return "Opening Spotify app…" }
        return "Not connected — preview-only playback"
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
