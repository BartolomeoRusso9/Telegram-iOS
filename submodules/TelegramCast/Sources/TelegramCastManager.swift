import Foundation
import GoogleCast

public enum TelegramCastConfiguration {
    public static let defaultMediaReceiverApplicationID = kGCKDefaultMediaReceiverApplicationID
    static let receiverInfoPlistKey = "TelegramCastReceiverApplicationID"

    // Chosen at build time (see docs/google-cast/README.md): the Cast context takes one receiver,
    // once per process. A missing or malformed value falls back to the default receiver.
    public static var receiverApplicationID: String {
        let value = Bundle.main.object(forInfoDictionaryKey: TelegramCastConfiguration.receiverInfoPlistKey) as? String
        return TelegramCastConfiguration.validated(value)
    }

    static func validated(_ value: String?) -> String {
        guard let value, value.count == 8, value.allSatisfy({ $0.isHexDigit }) else {
            return TelegramCastConfiguration.defaultMediaReceiverApplicationID
        }
        return value.uppercased()
    }
}

public enum TelegramCastSessionEvent {
    case started
    case resumed
    case suspended
    case ended(error: Error?)
    case failedToStart(error: Error)
}

// Owns the process-wide Cast context and reports session changes. Main thread only.
public final class TelegramCastManager: NSObject, GCKSessionManagerListener {
    public static let shared = TelegramCastManager()

    private var isSetUp = false
    private var observers: [UUID: (TelegramCastSessionEvent) -> Void] = [:]

    private override init() {
        super.init()
    }

    // Safe to call repeatedly: GCKCastContext may only be created once. Deferred to the first
    // video so that a launch that never shows one starts no discovery and no permission prompt.
    public func setupIfNeeded() {
        assert(Thread.isMainThread)
        if self.isSetUp {
            return
        }
        self.isSetUp = true
        let criteria = GCKDiscoveryCriteria(applicationID: TelegramCastConfiguration.receiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.startDiscoveryAfterFirstTapOnCastButton = true
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    // The SDK's own screen: play, pause, seek and stop on the receiver.
    public func presentExpandedControls() {
        guard self.isSetUp else {
            return
        }
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
    }

    public var hasConnectedSession: Bool {
        return self.isSetUp && GCKCastContext.sharedInstance().sessionManager.hasConnectedCastSession()
    }

    public var deviceName: String? {
        guard self.isSetUp else {
            return nil
        }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.device.friendlyName
    }

    var remoteMediaClient: GCKRemoteMediaClient? {
        guard self.isSetUp else {
            return nil
        }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    public func endSession() {
        guard self.isSetUp else {
            return
        }
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    public func addObserver(_ f: @escaping (TelegramCastSessionEvent) -> Void) -> () -> Void {
        assert(Thread.isMainThread)
        let id = UUID()
        self.observers[id] = f
        return { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    private func notify(_ event: TelegramCastSessionEvent) {
        for (_, f) in self.observers {
            f(event)
        }
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        self.notify(.started)
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        self.notify(.resumed)
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        self.notify(.suspended)
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        self.notify(.ended(error: error))
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        self.notify(.failedToStart(error: error))
    }
}
