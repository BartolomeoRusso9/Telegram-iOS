import Foundation
import UIKit
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import TelegramVoip
import FFMpegBinding
import UniversalMediaPlayer
import AccountContext
import TelegramCast

// Serves a live stream as HLS through the Cast local server. Telegram's own playlist generator
// runs only while casting, on its own connection to the stream's parts.
private final class CastLiveStreamSource: TelegramCastDynamicSource {
    private static let partTimeout: Double = 10.0
    static let entryPath = "live.m3u8"

    private let context = ExternalMediaStreamingContext(id: CallSessionInternalId(), rejoinNeeded: {})
    private let lock = NSLock()
    private let remuxQueue = Queue()
    private let muxer = FFMpegCastMuxer()
    private var hasAudioTrack = false
    private var cachedSegments: [Int: Data] = [:]
    private var firstPartDescription: String?
    private var baseIndex: Int?
    private var remuxFailed = false
    private var mediaDescription: String?
    private var playlistsServed = 0
    private var partsServed = 0
    private var partsFailed = 0
    private var firstRequestTimestamp: Double?
    private var requestLog: [String] = []
    private var stages: [String] = []
    private var partsHaveAudio: Bool?

    init(streamData: OngoingGroupCallContext.AudioStreamData) {
        self.context.setAudioStreamData(audioStreamData: streamData)
    }

    // Without audio in the parts the receiver is silent, and the phone stays the only sound.
    var receiverPlaysAudio: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.hasAudioTrack || self.partsHaveAudio == true
    }

    private static func lastPartIndex(playlist: String) -> Int? {
        for line in playlist.split(separator: "\n").reversed() {
            if let part = CastLiveStreamSource.parsePart(path: String(line)) {
                return part.index
            }
        }
        return nil
    }

    // Asks for one audio part to learn whether this stream sends its audio apart from the video.
    private func masterPlaylist() -> Signal<(data: Data, contentType: String)?, NoError> {
        let context = self.context
        return context.playlistData(quality: 0)
        |> take(1)
        |> mapToSignal { playlist -> Signal<Data?, NoError> in
            guard let index = CastLiveStreamSource.lastPartIndex(playlist: playlist) else {
                return .single(nil)
            }
            return context.audioPartData(index: index - 6)
            |> take(1)
            |> timeout(3.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
        }
        |> map { [weak self] audio -> (data: Data, contentType: String)? in
            let hasAudio = audio != nil
            if let self {
                self.lock.lock()
                self.hasAudioTrack = hasAudio
                self.lock.unlock()
            }
            let codecs = hasAudio ? "avc1.64001f,mp4a.40.2" : "avc1.64001f"
            let playlist = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=3400000,RESOLUTION=1280x720,CODECS=\"\(codecs)\"\nhls_level_0.m3u8\n"
            return (Data(playlist.utf8), "application/x-mpegurl")
        }
    }

    // What the first segment turned out to be, for the failure message.
    var diagnostic: String {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let requests = "playlists \(self.playlistsServed), parts \(self.partsServed), failed \(self.partsFailed)\n" + self.stages.joined(separator: ", ")
        guard let firstPartDescription = self.firstPartDescription else {
            return "no segment was requested; \(requests)"
        }
        return firstPartDescription + (self.remuxFailed ? ", remux failed" : ", remuxed to TS") + "\n\(self.mediaDescription ?? "unknown codecs")\n\(requests)"
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

    // Each part is a complete MP4 file, which HLS cannot play as a segment: it is rewrapped as
    // MPEG-TS without re-encoding, as SharedHLSServer does. The offset makes the timestamps of
    // consecutive parts continuous. It counts from before the first request because the
    // receiver may start anywhere in the playlist's window.
    private func transportStream(from data: Data, audio: Data?, index: Int) -> Data? {
        self.lock.lock()
        let hasAudioTrack = self.hasAudioTrack
        if let cached = self.cachedSegments[index] {
            // A retried segment: the audio encoder has moved past it.
            self.lock.unlock()
            return cached
        }
        let baseIndex: Int
        if let current = self.baseIndex {
            baseIndex = current
        } else {
            baseIndex = index - 64
            self.baseIndex = baseIndex
        }
        self.lock.unlock()

        let sourceFile = EngineTempBox.shared.tempFile(fileName: "part.mp4")
        let outputFile = EngineTempBox.shared.tempFile(fileName: "part.ts")
        defer {
            EngineTempBox.shared.dispose(sourceFile)
            EngineTempBox.shared.dispose(outputFile)
        }
        guard (try? data.write(to: URL(fileURLWithPath: sourceFile.path))) != nil else {
            return nil
        }
        self.lock.lock()
        let needsMediaDescription = self.mediaDescription == nil
        self.lock.unlock()
        if needsMediaDescription, let info = extractFFMpegMediaInfo(path: sourceFile.path) {
            let description = "video \(info.video?.codecName ?? "none") start \(info.video?.startTime.seconds ?? 0.0), audio \(info.audio?.codecName ?? "none")"
            self.lock.lock()
            self.mediaDescription = description
            self.partsHaveAudio = info.audio != nil
            self.lock.unlock()
        }
        self.mark("muxing")
        let offsetSeconds = Double(index - baseIndex)
        let isMuxed: Bool
        if hasAudioTrack {
            let audioFile = EngineTempBox.shared.tempFile(fileName: "part.ogg")
            defer {
                EngineTempBox.shared.dispose(audioFile)
            }
            var audioPath: String?
            if let audio, (try? audio.write(to: URL(fileURLWithPath: audioFile.path))) != nil {
                audioPath = audioFile.path
            }
            self.mark(audioPath == nil ? "no audio" : "audio \(audio?.count ?? 0)")
            isMuxed = self.muxer.muxVideoPath(sourceFile.path, audioPath: audioPath, to: outputFile.path, index: Int32(truncatingIfNeeded: index), offsetSeconds: offsetSeconds)
        } else {
            isMuxed = FFMpegLiveMuxer.remux(sourceFile.path, to: outputFile.path, offsetSeconds: offsetSeconds)
        }
        guard isMuxed else {
            self.lock.lock()
            self.remuxFailed = true
            self.lock.unlock()
            return nil
        }
        self.mark("muxed")
        let result = try? Data(contentsOf: URL(fileURLWithPath: outputFile.path))
        self.mark("read \(result?.count ?? -1)")
        if let result {
            self.lock.lock()
            self.cachedSegments[index] = result
            self.cachedSegments = self.cachedSegments.filter { $0.key > index - 8 }
            self.lock.unlock()
        }
        return result
    }

    // The first few steps of serving a segment, with their time.
    private func mark(_ stage: String) {
        self.lock.lock()
        if self.stages.count < 12 {
            let elapsed = CFAbsoluteTimeGetCurrent() - (self.firstRequestTimestamp ?? 0.0)
            self.stages.append("\(stage) +\(Int(elapsed * 1000.0))")
        }
        self.lock.unlock()
    }

    func resource(path: String, completion: @escaping ((data: Data, contentType: String)?) -> Void) -> () -> Void {
        let playlistContentType = "application/x-mpegurl"
        self.lock.lock()
        let startTimestamp = self.firstRequestTimestamp ?? CFAbsoluteTimeGetCurrent()
        self.firstRequestTimestamp = startTimestamp
        if self.requestLog.count < 5 {
            self.requestLog.append("\(path.prefix(14)) +\(Int((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000.0))ms")
        }
        self.lock.unlock()

        let signal: Signal<(data: Data, contentType: String)?, NoError>
        if path == CastLiveStreamSource.entryPath {
            // Telegram's own master playlist always announces audio, and the receiver fails when
            // a declared track never appears.
            signal = self.masterPlaylist()
        } else if path == "hls_level_0.m3u8" {
            signal = self.context.playlistData(quality: 0)
            |> map { value -> (data: Data, contentType: String)? in
                // Start near the live edge rather than at the receiver's default distance.
                let playlist = value.replacingOccurrences(of: "#EXTM3U\n", with: "#EXTM3U\n#EXT-X-START:TIME-OFFSET=-6.0\n")
                return (Data(playlist.utf8), playlistContentType)
            }
        } else if let part = CastLiveStreamSource.parsePart(path: path) {
            self.lock.lock()
            let wantsAudio = self.hasAudioTrack
            self.lock.unlock()
            let audioPart: Signal<Data?, NoError>
            if wantsAudio {
                audioPart = self.context.audioPartData(index: part.index)
                |> take(1)
                |> timeout(4.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
            } else {
                audioPart = .single(nil)
            }
            signal = combineLatest(self.context.partData(index: part.index, quality: part.quality) |> take(1), audioPart)
            |> take(1)
            // Serial on purpose: on a concurrent queue the completion overtakes the value while
            // it is being remuxed, and the finished segment is then dropped.
            |> deliverOn(self.remuxQueue)
            |> map { [weak self] video, audio -> (data: Data, contentType: String)? in
                guard let self, let video else {
                    return nil
                }
                self.mark("data")
                self.notePart(video)
                guard let segment = self.transportStream(from: video, audio: audio, index: part.index) else {
                    return nil
                }
                return (segment, "video/mp2t")
            }
        } else {
            completion(nil)
            return {}
        }
        let disposable = (signal
        |> take(1)
        |> timeout(CastLiveStreamSource.partTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))).start(next: { [weak self] value in
            if let self {
                self.lock.lock()
                if path.hasSuffix(".m3u8") {
                    self.playlistsServed += 1
                } else if value != nil {
                    self.partsServed += 1
                } else {
                    self.partsFailed += 1
                }
                self.lock.unlock()
                self.mark(value == nil ? "reply nil" : "reply \(value?.data.count ?? 0)")
            }
            completion(value)
        })
        return {
            disposable.dispose()
        }
    }
}

private final class CastLiveStreamController: TelegramCastLocalPlayback {
    // The call owns this controller.
    private weak var call: PresentationGroupCallImpl?
    private var switchController: TelegramCastSwitchController?
    private var source: CastLiveStreamSource?

    init(call: PresentationGroupCallImpl) {
        self.call = call

        let switchController = TelegramCastSwitchController(playback: self, mediaProvider: { [weak self] in
            return self?.media()
        })
        switchController.failed = { [weak self] reason in
            self?.presentFailure(reason: reason)
        }
        self.switchController = switchController
        switchController.transferIfSessionIsActive()
    }

    deinit {
        self.switchController?.finishRemotePlayback()
        self.call?.setCastPlaybackMuted(false)
    }

    private func media() -> TelegramCastMedia? {
        guard let call = self.call, let description = call.initialCall?.description else {
            return nil
        }
        let streamData = OngoingGroupCallContext.AudioStreamData(engine: call.accountContext.engine, callId: description.id, accessHash: description.accessHash, isExternalStream: call.isStream)
        let source = CastLiveStreamSource(streamData: streamData)
        self.source = source
        return TelegramCastMedia(source: .live(source, entryPath: CastLiveStreamSource.entryPath, contentType: "application/x-mpegurl"), title: description.title, duration: nil)
    }

    private func presentFailure(reason: String) {
        let text = "This live could not be played on the Cast device. It keeps playing here.\n\n\(reason)\n\(self.source?.diagnostic ?? "no stream")"
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.call?.accountContext.sharedContext.mainWindow?.presentNative(alert)
    }

    var castCurrentPosition: Double {
        return 0.0
    }

    func castPauseLocalPlayback() {
        if self.source?.receiverPlaysAudio == true {
            self.call?.setCastPlaybackMuted(true)
        }
    }

    func castResumeLocalPlayback(at position: Double) {
        self.call?.setCastPlaybackMuted(false)
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

        func update(component: LiveCastButtonComponent, availableSize: CGSize) -> CGSize {
            let size = CGSize(width: component.size, height: component.size)
            if self.button == nil {
                let button = TelegramCastButton(frame: CGRect(origin: CGPoint(), size: size))
                self.button = button
                self.addSubview(button)
            }
            self.button?.frame = CGRect(origin: CGPoint(), size: size)
            if component.call.castController == nil {
                component.call.castController = CastLiveStreamController(call: component.call)
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
