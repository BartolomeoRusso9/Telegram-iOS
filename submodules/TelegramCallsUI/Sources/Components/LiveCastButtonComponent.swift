import Foundation
import UIKit
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import TelegramVoip
import AccountContext
import TelegramCast

// Serves a live stream as HLS through the Cast local server. Telegram's own playlist generator
// runs only while casting, on its own connection to the stream's parts.
private final class CastLiveStreamSource: TelegramCastDynamicSource {
    private static let partTimeout: Double = 10.0

    private let context = ExternalMediaStreamingContext(id: CallSessionInternalId(), rejoinNeeded: {})
    private let lock = NSLock()
    private var firstPartDescription: String?

    init(streamData: OngoingGroupCallContext.AudioStreamData) {
        self.context.setAudioStreamData(audioStreamData: streamData)
    }

    // What the first segment turned out to be, for the failure message.
    var diagnostic: String {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.firstPartDescription ?? "no segment was requested"
    }

    private static func parsePart(path: String) -> (quality: Int, index: Int)? {
        guard path.hasPrefix("hls_stream"), path.hasSuffix(".ts") else {
            return nil
        }
        let components = path.dropFirst("hls_stream".count).dropLast(".ts".count).split(separator: "_")
        guard components.count == 2, let quality = Int(components[0]), let index = Int(components[1]) else {
            return nil
        }
        return (quality, index)
    }

    private static func describe(_ data: Data) -> String {
        let head = data.prefix(12)
        if head.count >= 8, let type = String(data: head.subdata(in: head.startIndex + 4 ..< head.startIndex + 8), encoding: .ascii), type.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "\(type), \(data.count) bytes"
        }
        return "\(head.map { String(format: "%02x", $0) }.joined()), \(data.count) bytes"
    }

    private func notePart(_ data: Data) {
        self.lock.lock()
        if self.firstPartDescription == nil {
            self.firstPartDescription = CastLiveStreamSource.describe(data)
            Logger.shared.log("TelegramCast", "First live segment: \(self.firstPartDescription ?? "")")
        }
        self.lock.unlock()
    }

    func resource(path: String, completion: @escaping ((data: Data, contentType: String)?) -> Void) -> () -> Void {
        let playlistContentType = "application/x-mpegurl"
        let signal: Signal<(data: Data, contentType: String)?, NoError>
        if path == "master.m3u8" {
            signal = self.context.masterPlaylistData()
            |> map { value -> (data: Data, contentType: String)? in
                return (Data(value.utf8), playlistContentType)
            }
        } else if path == "hls_level_0.m3u8" || path == "hls_level_1.m3u8" {
            signal = self.context.playlistData(quality: path == "hls_level_0.m3u8" ? 0 : 1)
            |> map { value -> (data: Data, contentType: String)? in
                return (Data(value.utf8), playlistContentType)
            }
        } else if let part = CastLiveStreamSource.parsePart(path: path) {
            signal = self.context.partData(index: part.index, quality: part.quality)
            |> map { [weak self] data -> (data: Data, contentType: String)? in
                guard let data else {
                    return nil
                }
                self?.notePart(data)
                return (data, "video/mp2t")
            }
        } else {
            completion(nil)
            return {}
        }
        let disposable = (signal
        |> take(1)
        |> timeout(CastLiveStreamSource.partTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))).start(next: { value in
            completion(value)
        })
        return {
            disposable.dispose()
        }
    }
}

private final class CastLiveStreamController: TelegramCastLocalPlayback {
    private let call: PresentationGroupCallImpl
    private var switchController: TelegramCastSwitchController?
    private var source: CastLiveStreamSource?

    init(call: PresentationGroupCallImpl) {
        self.call = call

        let switchController = TelegramCastSwitchController(playback: self, mediaProvider: { [weak self] in
            return self?.media()
        })
        switchController.failed = { [weak self] _ in
            self?.presentFailure()
        }
        self.switchController = switchController
        switchController.transferIfSessionIsActive()
    }

    deinit {
        self.switchController?.finishRemotePlayback()
        self.call.setCastPlaybackMuted(false)
    }

    private func media() -> TelegramCastMedia? {
        guard let description = self.call.initialCall?.description else {
            return nil
        }
        let streamData = OngoingGroupCallContext.AudioStreamData(engine: self.call.accountContext.engine, callId: description.id, accessHash: description.accessHash, isExternalStream: self.call.isStream)
        let source = CastLiveStreamSource(streamData: streamData)
        self.source = source
        return TelegramCastMedia(source: .live(source, entryPath: "master.m3u8", contentType: "application/x-mpegurl"), title: description.title, duration: nil)
    }

    private func presentFailure() {
        let text = "This live could not be played on the Cast device. It keeps playing here.\n\n\(self.source?.diagnostic ?? "no stream")"
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.call.accountContext.sharedContext.mainWindow?.presentNative(alert)
    }

    var castCurrentPosition: Double {
        return 0.0
    }

    func castPauseLocalPlayback() {
        self.call.setCastPlaybackMuted(true)
    }

    func castResumeLocalPlayback(at position: Double) {
        self.call.setCastPlaybackMuted(false)
    }
}

public final class LiveCastButtonComponent: Component {
    public let call: PresentationGroupCallImpl
    public let size: CGFloat

    public init(call: PresentationGroupCallImpl, size: CGFloat) {
        self.call = call
        self.size = size
    }

    public static func ==(lhs: LiveCastButtonComponent, rhs: LiveCastButtonComponent) -> Bool {
        return lhs.call === rhs.call && lhs.size == rhs.size
    }

    public final class View: UIView {
        private var button: TelegramCastButton?
        private var controller: CastLiveStreamController?
        private weak var call: PresentationGroupCallImpl?

        func update(component: LiveCastButtonComponent, availableSize: CGSize) -> CGSize {
            let size = CGSize(width: component.size, height: component.size)
            if self.button == nil {
                let button = TelegramCastButton(frame: CGRect(origin: CGPoint(), size: size))
                self.button = button
                self.addSubview(button)
            }
            self.button?.frame = CGRect(origin: CGPoint(), size: size)
            if self.call !== component.call {
                self.call = component.call
                self.controller = CastLiveStreamController(call: component.call)
            }
            return size
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}
