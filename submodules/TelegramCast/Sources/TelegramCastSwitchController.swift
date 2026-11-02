import Foundation

// What the switch needs from the local player. Main thread only.
public protocol TelegramCastLocalPlayback: AnyObject {
    var castCurrentPosition: Double { get }
    func castPauseLocalPlayback()
    func castResumeLocalPlayback(at position: Double)
}

public enum TelegramCastMediaSource {
    // A URL the receiver fetches by itself.
    case remote(url: URL, contentType: String)
    // Bytes only this device can read, served for the length of the session.
    case local(TelegramCastByteSource)
    // A live stream's playlist and segments, served for the length of the session.
    case live(TelegramCastDynamicSource, entryPath: String, contentType: String)
}

public struct TelegramCastMedia {
    public let source: TelegramCastMediaSource
    public let title: String?
    public let duration: Double?

    public init(source: TelegramCastMediaSource, title: String?, duration: Double?) {
        self.source = source
        self.title = title
        self.duration = duration
    }
}

// Moves one video from the local player to the session's receiver and back.
// Local playback is paused only after the receiver confirms it is playing, and every failure
// before that leaves it running. Main thread only.
public final class TelegramCastSwitchController {
    public enum State {
        case local
        case transferring
        case remote
    }

    public private(set) var state: State = .local
    public var stateUpdated: ((State) -> Void)?
    public var failed: ((String) -> Void)?

    private weak var playback: TelegramCastLocalPlayback?
    private let mediaProvider: () -> TelegramCastMedia?
    private let player = TelegramCastPlayer()
    private var server: TelegramCastLocalServer?
    private var removeObserver: (() -> Void)?
    // Bumped by every start and end, so that a late callback of an abandoned transfer is ignored.
    private var transferId = 0

    public init(playback: TelegramCastLocalPlayback, mediaProvider: @escaping () -> TelegramCastMedia?) {
        self.playback = playback
        self.mediaProvider = mediaProvider

        self.removeObserver = TelegramCastManager.shared.addObserver { [weak self] event in
            self?.handle(event)
        }
        self.player.stateUpdated = { [weak self] state in
            if case .finished = state {
                self?.endRemotePlayback()
            }
        }
    }

    deinit {
        self.removeObserver?()
        self.server?.stop()
    }

    public var isRemote: Bool {
        return self.state == .remote
    }

    public func play() {
        self.player.play()
    }

    public func pause() {
        self.player.pause()
    }

    public func seek(to position: Double) {
        self.player.seek(to: position)
    }

    // Called when the gallery shows the video during a session the user already started.
    public func transferIfSessionIsActive() {
        if TelegramCastManager.shared.hasConnectedSession {
            self.startTransfer()
        }
    }

    public func stopCasting() {
        // endSession reports .ended, which restores local playback.
        TelegramCastManager.shared.endSession()
    }

    // For when the video leaves the screen: its bytes stop being served, so the receiver must
    // stop too. The session stays connected for the next video.
    public func finishRemotePlayback() {
        switch self.state {
        case .local:
            break
        case .transferring:
            self.cancelTransfer(reason: nil)
        case .remote:
            self.player.stop()
            self.releaseRemote()
            self.set(state: .local)
        }
    }

    private func handle(_ event: TelegramCastSessionEvent) {
        switch event {
        case .started, .resumed:
            self.startTransfer()
        case .suspended:
            // The SDK reconnects by itself; the remote state holds until .resumed or .ended.
            break
        case .ended:
            self.endRemotePlayback()
        case .failedToStart:
            self.cancelTransfer(reason: nil)
        }
    }

    private func set(state: State) {
        if self.state != state {
            self.state = state
            self.stateUpdated?(state)
        }
    }

    private func startTransfer() {
        guard self.state == .local, let playback = self.playback else {
            return
        }
        guard let media = self.mediaProvider() else {
            self.failed?("unsupported")
            return
        }
        self.transferId += 1
        let transferId = self.transferId
        self.set(state: .transferring)
        let startPosition = playback.castCurrentPosition

        switch media.source {
        case let .remote(url, contentType):
            self.load(url: url, contentType: contentType, media: media, startPosition: startPosition, transferId: transferId)
        case let .local(source):
            guard let server = TelegramCastLocalServer(source: source) else {
                self.cancelTransfer(reason: "server")
                return
            }
            self.server = server
            server.start { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.transferId == transferId else {
                        server.stop()
                        return
                    }
                    switch result {
                    case let .success(url):
                        self.load(url: url, contentType: source.contentType, media: media, startPosition: startPosition, transferId: transferId)
                    case .failure:
                        self.cancelTransfer(reason: "network")
                    }
                }
            }
        case let .live(source, entryPath, contentType):
            guard let server = TelegramCastLocalServer(dynamicSource: source) else {
                self.cancelTransfer(reason: "server")
                return
            }
            self.server = server
            server.start(relativePath: entryPath) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.transferId == transferId else {
                        server.stop()
                        return
                    }
                    switch result {
                    case let .success(url):
                        self.load(url: url, contentType: contentType, media: media, startPosition: 0.0, transferId: transferId, isLive: true)
                    case .failure:
                        self.cancelTransfer(reason: "network")
                    }
                }
            }
        }
    }

    private func load(url: URL, contentType: String, media: TelegramCastMedia, startPosition: Double, transferId: Int, isLive: Bool = false) {
        let request = TelegramCastLoadRequest(url: url, contentType: contentType, title: media.title, duration: media.duration, startPosition: startPosition, isLive: isLive)
        self.player.load(request) { [weak self] result in
            guard let self, self.transferId == transferId else {
                return
            }
            switch result {
            case .success:
                self.playback?.castPauseLocalPlayback()
                self.set(state: .remote)
            case let .failure(error):
                if case .loadFailed(cancelled: true) = error {
                    self.cancelTransfer(reason: nil)
                } else {
                    self.cancelTransfer(reason: self.player.failureDetail ?? "load")
                }
            }
        }
    }

    private func releaseRemote() {
        self.transferId += 1
        self.player.detach()
        self.server?.stop()
        self.server = nil
    }

    private func cancelTransfer(reason: String?) {
        guard self.state == .transferring else {
            return
        }
        self.releaseRemote()
        self.set(state: .local)
        if let reason {
            self.failed?(reason)
        }
    }

    private func endRemotePlayback() {
        switch self.state {
        case .local:
            break
        case .transferring:
            self.cancelTransfer(reason: nil)
        case .remote:
            let position = self.player.currentPosition
            self.releaseRemote()
            self.set(state: .local)
            self.playback?.castResumeLocalPlayback(at: position)
        }
    }
}
