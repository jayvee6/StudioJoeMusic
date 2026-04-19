import SwiftUI

public struct SpotifyLibraryView: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @State private var auth = SpotifyAuth()
    @State private var tracks: [SpotifyTrack] = []
    @State private var isLoading = false
    @State private var searchQuery = ""
    @State private var localError: String?
    public var onDismiss: () -> Void

    public init(viewModel: VisualizerViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Group {
                if !AppConfig.isSpotifyConfigured {
                    configureHint
                } else if !auth.isConnected {
                    connectPanel
                } else {
                    libraryList
                }
            }
            .navigationTitle("Spotify")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
                if auth.isConnected {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if let p = auth.profile {
                                Text("Signed in as \(p.display_name ?? p.id)")
                                if let product = p.product {
                                    Text("Plan: \(product)")
                                }
                            }
                            Button("Sign out", role: .destructive) {
                                auth.signOut()
                                tracks = []
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: auth.isConnected) {
            if auth.isConnected { await reloadSavedTracks() }
        }
    }

    private var configureHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Spotify not configured")
                .font(.title2.weight(.semibold))
            Text("Register an app at developer.spotify.com/dashboard, add `\(AppConfig.spotifyRedirectURI)` as a redirect URI, then set `SPOTIFY_CLIENT_ID` in Info.plist.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 54))
                .foregroundStyle(StudioJoeColors.accent)
            Text("Connect your Spotify")
                .font(.title2.weight(.semibold))
            Text("We'll fetch your liked songs and play 30-second previews through the visualizer.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button {
                Task { await auth.connect() }
            } label: {
                HStack(spacing: 8) {
                    if auth.isAuthorizing {
                        ProgressView().tint(.white)
                    }
                    Text(auth.isAuthorizing ? "Connecting…" : "Connect Spotify")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.glassProminent)
            .disabled(auth.isAuthorizing)

            if let err = auth.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryList: some View {
        List {
            if isLoading && tracks.isEmpty {
                ProgressView("Loading liked tracks…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            ForEach(tracks) { track in
                Button {
                    play(track)
                } label: {
                    trackRow(track)
                }
                .disabled(track.previewURL == nil)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await reloadSavedTracks() }
        .searchable(text: $searchQuery, prompt: "Search tracks")
        .onSubmit(of: .search) {
            Task { await runSearch() }
        }
        .overlay(alignment: .bottom) {
            if let err = localError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
    }

    private func trackRow(_ track: SpotifyTrack) -> some View {
        HStack(spacing: 12) {
            artwork(for: track)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).foregroundStyle(StudioJoeColors.label1).lineLimit(1)
                Text(track.primaryArtist).foregroundStyle(StudioJoeColors.label2)
                    .font(.footnote).lineLimit(1)
            }
            Spacer()
            if track.previewURL == nil {
                Text("no preview")
                    .font(.caption2)
                    .foregroundStyle(StudioJoeColors.label3)
            } else {
                Image(systemName: "play.fill")
                    .foregroundStyle(StudioJoeColors.accent)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artwork(for track: SpotifyTrack) -> some View {
        if let url = track.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 40)
        }
    }

    // MARK: - Actions

    private func reloadSavedTracks() async {
        isLoading = true
        defer { isLoading = false }
        let catalog = SpotifyCatalog(auth: auth)
        do {
            let fresh = try await catalog.savedTracks(limit: 50)
            tracks = fresh
            localError = nil
        } catch {
            localError = (error as NSError).localizedDescription
        }
    }

    private func runSearch() async {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            await reloadSavedTracks()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let catalog = SpotifyCatalog(auth: auth)
        do {
            tracks = try await catalog.searchTracks(query: searchQuery)
            localError = nil
        } catch {
            localError = (error as NSError).localizedDescription
        }
    }

    private func play(_ track: SpotifyTrack) {
        guard let url = track.previewURL else { return }
        Task {
            await viewModel.play(
                remoteURL: url,
                title: track.name,
                artist: track.primaryArtist,
                durationSec: Double(track.duration_ms) / 1000.0
            )
            onDismiss()
        }
    }
}
