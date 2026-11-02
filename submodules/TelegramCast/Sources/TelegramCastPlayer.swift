import Foundation
import GoogleCast

public struct TelegramCastLoadRequest {
    public let url: URL
    public let contentType: String
    public let title: String?
    public let duration: Double?
    public let startPosition: Double
    public let isLive: Bool

    public init(url: URL, contentType: String, title: String?, duration: Double?, startPosition: Double, isLive: Bool = false) {
        self.isLive = isLive
        self.url = url
        self.contentType = contentType
        self.title = title
        self.duration = duration
        self.startPosition = startPosition
    }
}

public enum TelegramCastPlayerError: Error {
    case noSession
    case loadFailed(cancelled: Bool)
    case timedOut
}

// Loads one media item on the session's receiver and follows it. Main thread only.
public final class TelegramCastPlayer: NSObject, GCKRemoteMediaClientListener, GCKRequestDelegate {
    public enum PlaybackState {
        case idle
        case loading
        case buffering
        case playing
        case paused
        // The receiver stopped by itself: the end of the video, or a playback error.
        case finished
    }

    private static let confirmationTimeout: Double = 20.0

    public private(set) var state: PlaybackState = .idle
    public private(set) var lastKnownPosition: Double = 0.0
    public var stateUpdated: ((PlaybackState) -> Void)?

    private weak var client: GCKRemoteMediaClient?
    private var loadRequest: GCKRequest?
    private var expectedURL: URL?
    private var confirmation: ((Result<Void, TelegramCastPlayerError>) -> Void)?
    private var confirmationTimer: Timer?

    deinit {
        self.confirmationTimer?.invalidate()
        self.client?.remove(self)
    }

    // Completes only once the receiver reports this media as playing, not when it accepts the
    // request: the caller stops local playback on success, and a device that took the request
    // but cannot fetch or decode the video must leave local playback untouched.
    public func load(_ request: TelegramCastLoadRequest, completion: @escaping (Result<Void, TelegramCastPlayerError>) -> Void) {
        assert(Thread.isMainThread)
        guard let client = TelegramCastManager.shared.remoteMediaClient else {
            completion(.failure(.noSession))
            return
        }
        self.finishConfirmation(.failure(.loadFailed(cancelled: true)))
        self.client?.remove(self)
        self.client = client
        client.add(self)

        let metadata = GCKMediaMetadata(metadataType: .movie)
        if let title = request.title, !title.isEmpty {
            metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        }
        let builder = GCKMediaInformationBuilder(contentURL: request.url)
        builder.streamType = request.isLive ? .live : .buffered
        builder.contentType = request.contentType
        builder.metadata = metadata
        if let duration = request.duration, duration > 0.0 {
            builder.streamDuration = duration
        }

        let loadData = GCKMediaLoadRequestDataBuilder()
        loadData.mediaInformation = builder.build()
        loadData.autoplay = true
        if !request.isLive {
            loadData.startTime = request.startPosition
        }

        self.expectedURL = request.url
        self.lastKnownPosition = request.startPosition
        self.confirmation = completion
        self.update(state: .loading)
        self.confirmationTimer = Timer.scheduledTimer(withTimeInterval: TelegramCastPlayer.confirmationTimeout, repeats: false) { [weak self] _ in
            self?.finishConfirmation(.failure(.timedOut))
        }

        let gckRequest = client.loadMedia(with: loadData.build())
        gckRequest.delegate = self
        self.loadRequest = gckRequest
    }

    public func play() {
        _ = self.client?.play()
    }

    public func pause() {
        _ = self.client?.pause()
    }

    public func seek(to position: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = position
        options.resumeState = .unchanged
        _ = self.client?.seek(with: options)
    }

    public func stop() {
        _ = self.client?.stop()
    }

    public func detach() {
        self.finishConfirmation(.failure(.loadFailed(cancelled: true)))
        self.client?.remove(self)
        self.client = nil
        self.expectedURL = nil
        self.update(state: .idle)
    }

    public var currentPosition: Double {
        if let client = self.client, client.connected {
            let position = client.approximateStreamPosition()
            if position > 0.0 {
                return position
            }
        }
        return self.lastKnownPosition
    }

    private func update(state: PlaybackState) {
        if self.state != state {
            self.state = state
            self.stateUpdated?(state)
        }
    }

    private func finishConfirmation(_ result: Result<Void, TelegramCastPlayerError>) {
        self.confirmationTimer?.invalidate()
        self.confirmationTimer = nil
        if let confirmation = self.confirmation {
            self.confirmation = nil
            confirmation(result)
        }
    }

    public func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else {
            return
        }
        // A status for what was playing before this load says nothing about this load.
        if let expectedURL = self.expectedURL, let contentURL = mediaStatus.mediaInformation?.contentURL, contentURL != expectedURL {
            return
        }
        switch mediaStatus.playerState {
        case .playing:
            self.lastKnownPosition = mediaStatus.streamPosition
            self.update(state: .playing)
            self.finishConfirmation(.success(()))
        case .paused:
            self.lastKnownPosition = mediaStatus.streamPosition
            self.update(state: .paused)
        case .buffering:
            self.update(state: .buffering)
        case .loading:
            self.update(state: .loading)
        case .idle:
            if self.confirmation != nil {
                // Still idle before the load is picked up, unless the receiver gave a reason.
                if mediaStatus.idleReason == .error || mediaStatus.idleReason == .cancelled {
                    self.update(state: .idle)
                    self.finishConfirmation(.failure(.loadFailed(cancelled: false)))
                }
            } else if self.state != .idle {
                self.update(state: .finished)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    public func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard request === self.loadRequest else {
            return
        }
        self.update(state: .idle)
        // GCKErrorCodeCancelled includes the user declining the Cast terms; the SDK forbids
        // retrying automatically after it.
        self.finishConfirmation(.failure(.loadFailed(cancelled: error.code == GCKErrorCode.cancelled.rawValue)))
    }

    public func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        guard request === self.loadRequest else {
            return
        }
        self.update(state: .idle)
        self.finishConfirmation(.failure(.loadFailed(cancelled: true)))
    }
}
