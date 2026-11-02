import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import PresentationDataUtils
import TelegramUniversalVideoContent
import UniversalMediaPlayer
import TelegramCast

final class CastHeaderButtonNode: ASDisplayNode {
    private static let size = CGSize(width: 44.0, height: 44.0)

    override init() {
        super.init()

        self.setViewBlock({
            return TelegramCastButton(frame: CGRect(origin: CGPoint(), size: CastHeaderButtonNode.size))
        })
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CastHeaderButtonNode.size
    }
}

// Connects one gallery video to Google Cast. All of it lives here so that
// UniversalVideoGalleryItem carries only the calls that create and activate this object.
final class CastGalleryItemController: TelegramCastLocalPlayback {
    private static var didCheckForUpdate = false

    let buttonNode = CastHeaderButtonNode()

    private let context: AccountContext
    private let content: UniversalVideoContent
    private let title: String?
    private let present: (ViewController) -> Void
    private weak var videoNode: UniversalVideoNode?
    private let statusDisposable = MetaDisposable()
    private var switchController: TelegramCastSwitchController?
    private var position: Double = 0.0

    // The video types that can reach a receiver. Secret and copy-protected media must never
    // reach one, and the caller does not create a controller for them.
    static func canCast(content: UniversalVideoContent) -> Bool {
        return content is NativeVideoContent || content is HLSVideoContent || content is SystemVideoContent
    }

    init(context: AccountContext, content: UniversalVideoContent, title: String?, videoNode: UniversalVideoNode, present: @escaping (ViewController) -> Void) {
        self.context = context
        self.content = content
        self.title = title
        self.videoNode = videoNode
        self.present = present

        self.statusDisposable.set((videoNode.status
        |> deliverOnMainQueue).start(next: { [weak self] status in
            self?.updated(status: status)
        }))

        CastGalleryItemController.checkForUpdate(context: context, present: present)
    }

    deinit {
        self.statusDisposable.dispose()
    }

    // The gallery keeps neighbouring items alive, so only the one on screen may take a session.
    func setIsVisible(_ isVisible: Bool) {
        if isVisible {
            if self.switchController == nil {
                let switchController = TelegramCastSwitchController(playback: self, mediaProvider: { [weak self] in
                    return self?.media()
                })
                switchController.stateUpdated = { state in
                    if case .remote = state {
                        TelegramCastManager.shared.presentExpandedControls()
                    }
                }
                switchController.failed = { [weak self] _ in
                    self?.presentFailure()
                }
                self.switchController = switchController
                switchController.transferIfSessionIsActive()
            }
        } else if let switchController = self.switchController {
            switchController.finishRemotePlayback()
            self.switchController = nil
        }
    }

    private func updated(status: MediaPlayerStatus?) {
        guard let status else {
            return
        }
        self.position = status.timestamp
        // The gallery's own controls and its autoplay can start this player at any time. Audio
        // must not come from both devices, so the receiver stays in charge.
        if case .playing = status.status, self.switchController?.isRemote == true {
            self.videoNode?.pause()
            TelegramCastManager.shared.presentExpandedControls()
        }
    }

    private func media() -> TelegramCastMedia? {
        let engine = self.context.engine
        if let content = self.content as? NativeVideoContent {
            return TelegramCastMediaProvider.media(engine: engine, file: content.fileReference, userLocation: content.userLocation, title: self.title, duration: content.duration)
        } else if let content = self.content as? HLSVideoContent {
            // A quality set holds complete MP4 files. Cast support for AV1 varies by device, so
            // it is excluded here by declaring no AV1 decoder.
            let configuration = HLSCodecConfiguration(isHardwareAv1Supported: false, isSoftwareAv1Supported: false)
            let qualities = HLSQualitySet(baseFile: content.fileReference, codecConfiguration: configuration)?.qualityFiles ?? [:]
            let best = qualities.filter({ $0.key <= 1080 }).max(by: { $0.key < $1.key })?.value ?? content.fileReference
            return TelegramCastMediaProvider.media(engine: engine, file: best, userLocation: content.userLocation, title: self.title, duration: content.duration)
        } else if let content = self.content as? SystemVideoContent {
            return TelegramCastMediaProvider.media(externalUrl: content.url, title: self.title, duration: content.duration)
        }
        return nil
    }

    private func presentFailure() {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.present(textAlertController(context: self.context, title: nil, text: "This video could not be played on the Cast device. It keeps playing here.", actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    }

    private static func checkForUpdate(context: AccountContext, present: @escaping (ViewController) -> Void) {
        if CastGalleryItemController.didCheckForUpdate {
            return
        }
        CastGalleryItemController.didCheckForUpdate = true
        TelegramCastUpdateChecker.check { update in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let installedVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            let installedBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
            let text = "Installed: \(installedVersion) (\(installedBuild))\nAvailable: \(update.version) (\(update.build)), \(update.releaseDate)\n\n\(update.notes)"
            present(textAlertController(context: context, title: "Update available", text: text, actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]))
        }
    }

    var castCurrentPosition: Double {
        return self.position
    }

    func castPauseLocalPlayback() {
        self.videoNode?.pause()
    }

    func castResumeLocalPlayback(at position: Double) {
        self.videoNode?.seek(position)
        self.videoNode?.play()
    }
}
