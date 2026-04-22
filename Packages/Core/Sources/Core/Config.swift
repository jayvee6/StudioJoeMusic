import Foundation

public enum AppConfig {
    /// Fetched from Info.plist key `SPOTIFY_CLIENT_ID` (falls back to empty string so
    /// the app still launches; UI will nudge the user to register).
    public static var spotifyClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "SPOTIFY_CLIENT_ID") as? String) ?? ""
    }

    /// Custom URL scheme registered in Info.plist CFBundleURLTypes.
    public static let spotifyRedirectURI = "studiojoe-musicplayer://spotify-callback"
    public static let spotifyCallbackScheme = "studiojoe-musicplayer"

    public static let spotifyAuthScopes: [String] = [
        // Catalog browsing
        "user-library-read",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-follow-read",
        "user-read-private",
        "user-read-email",
        // Playback control — required for Web API transport calls and
        // SPTAppRemote to drive the Spotify app on this device.
        "streaming",
        "app-remote-control",
        "user-modify-playback-state",
        "user-read-playback-state"
    ]

    public static var isSpotifyConfigured: Bool {
        !spotifyClientID.isEmpty
    }
}
