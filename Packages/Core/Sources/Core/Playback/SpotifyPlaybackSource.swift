import Foundation
import SpotifyiOS
import Combine
import UIKit
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SpotifyPlaybackSource")

/// A lightweight Combine-friendly wrapper around `SPTAppRemote` that drives
/// full-track Spotify playback via the installed Spotify app (Premium required).
///
/// This is an *independent* auth + control path from `SpotifyAuth`, which
/// handles PKCE for the Web API. The two live side by side on purpose:
/// `SpotifyAuth` talks to the Web API (library browsing, search, etc.) while
/// this source talks to the Spotify app on-device via the app-switch handshake.
@MainActor
public final class SpotifyPlaybackSource: NSObject, ObservableObject {

    // MARK: - Observable state

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isAuthorizing: Bool = false
    @Published public private(set) var lastError: String?

    /// Last known track info, republished whenever SPTAppRemote fires a
    /// player-state change notification.
    @Published public private(set) var currentTrack: SpotifyRemoteTrack?
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var positionSec: Double = 0

    // MARK: - Internals

    private let appRemote: SPTAppRemote

    // MARK: - Init

    public override init() {
        // `AppConfig.spotifyRedirectURI` is a hardcoded literal in the project,
        // so force-unwrapping `URL(string:)` here is safe at init time.
        let config = SPTConfiguration(
            clientID: AppConfig.spotifyClientID,
            redirectURL: URL(string: AppConfig.spotifyRedirectURI)!
        )
        self.appRemote = SPTAppRemote(configuration: config, logLevel: .debug)
        super.init()
        self.appRemote.delegate = self
    }

    // MARK: - Auth + connection lifecycle

    /// Start the app-switch authorization + connect flow. Opens the installed
    /// Spotify app. The Spotify app then returns to us via the custom URL
    /// scheme (handled by `handleCallback(url:)` below).
    ///
    /// Returns `false` immediately if the Spotify app isn't installed and
    /// sets `lastError` to a user-friendly message. The async completion from
    /// `authorizeAndPlayURI(_:completionHandler:)` also updates `lastError`
    /// if the app-switch itself fails.
    @discardableResult
    public func connect() -> Bool {
        guard let spotifyURL = URL(string: "spotify:") else { return false }
        guard UIApplication.shared.canOpenURL(spotifyURL) else {
            lastError = "Spotify app not installed. Install Spotify from the App Store."
            return false
        }
        isAuthorizing = true
        lastError = nil
        // Passing "" means "just authorize, don't auto-start playback".
        appRemote.authorizeAndPlayURI("") { [weak self] success in
            // The completion reports only whether the app-switch attempt
            // itself could be made. The real success/failure arrives via
            // SPTAppRemoteDelegate after the callback URL is processed.
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    self.isAuthorizing = false
                    self.lastError = "Could not open Spotify for authorization."
                }
            }
        }
        return true
    }

    /// Resolve the callback URL from the app-switch flow. Call from
    /// `.onOpenURL` at the SwiftUI root (or the SceneDelegate equivalent).
    /// Returns `true` iff the URL was a Spotify SDK callback we recognized.
    @discardableResult
    public func handleCallback(url: URL) -> Bool {
        guard let params = appRemote.authorizationParameters(from: url) else {
            isAuthorizing = false
            return false
        }
        if let token = params[SPTAppRemoteAccessTokenKey] {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            // Connection completes asynchronously via SPTAppRemoteDelegate;
            // `isAuthorizing` flips off in
            // `appRemoteDidEstablishConnection` / `didFailConnectionAttemptWithError`.
            return true
        }
        if let err = params[SPTAppRemoteErrorDescriptionKey] {
            lastError = err
            isAuthorizing = false
            return true    // The URL *was* ours — we just got back an error.
        }
        isAuthorizing = false
        return false
    }

    /// Sever the connection and forget the access token. Also stops
    /// subscription to player state.
    public func disconnect() {
        if appRemote.isConnected {
            appRemote.playerAPI?.unsubscribe(toPlayerState: nil)
            appRemote.disconnect()
        }
        appRemote.connectionParameters.accessToken = nil
        isConnected = false
        isAuthorizing = false
        currentTrack = nil
        isPlaying = false
        positionSec = 0
    }

    // MARK: - Playback control

    /// Play a Spotify track by URI (e.g. `"spotify:track:0e7ipj03S05BNilyu5bRzt"`).
    /// Throws if not connected.
    public func play(uri: String) async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.play(uri) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func pause() async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.pause { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func resume() async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.resume { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func skipNext() async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.skip(toNext: { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    public func skipPrevious() async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.skip(toPrevious: { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// Seek to an absolute position in the current track.
    public func seek(to seconds: Double) async throws {
        guard isConnected, let api = appRemote.playerAPI else {
            throw SpotifyPlaybackSource.notConnectedError()
        }
        let ms = Int(seconds * 1000)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            api.seek(toPosition: ms) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    // MARK: - Helpers

    private static func notConnectedError() -> NSError {
        NSError(
            domain: "SpotifyPlaybackSource",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected to Spotify"]
        )
    }
}

// MARK: - SPTAppRemoteDelegate

extension SpotifyPlaybackSource: SPTAppRemoteDelegate {
    public func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        log.info("SPTAppRemote connected")
        isAuthorizing = false
        isConnected = true
        lastError = nil
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.lastError = "Player subscription failed: \(error.localizedDescription)"
                }
            }
        })
    }

    public func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        log.info("SPTAppRemote disconnected: \(error?.localizedDescription ?? "clean", privacy: .public)")
        isConnected = false
        isAuthorizing = false
        currentTrack = nil
        isPlaying = false
    }

    public func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        log.error("SPTAppRemote connection failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        isConnected = false
        isAuthorizing = false
        lastError = error?.localizedDescription ?? "Connection failed"
    }
}

// MARK: - SPTAppRemotePlayerStateDelegate

extension SpotifyPlaybackSource: SPTAppRemotePlayerStateDelegate {
    public func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let uri = playerState.track.uri
        let id = uri.components(separatedBy: ":").last ?? uri
        currentTrack = SpotifyRemoteTrack(
            uri: uri,
            id: id,
            name: playerState.track.name,
            artistName: playerState.track.artist.name,
            durationSec: Double(playerState.track.duration) / 1000.0
        )
        isPlaying = !playerState.isPaused
        positionSec = Double(playerState.playbackPosition) / 1000.0
    }
}

// MARK: - Public value type

public struct SpotifyRemoteTrack: Equatable, Sendable {
    public let uri: String
    public let id: String       // extracted from uri (part after "spotify:track:")
    public let name: String
    public let artistName: String
    public let durationSec: Double

    public init(uri: String, id: String, name: String, artistName: String, durationSec: Double) {
        self.uri = uri
        self.id = id
        self.name = name
        self.artistName = artistName
        self.durationSec = durationSec
    }
}
