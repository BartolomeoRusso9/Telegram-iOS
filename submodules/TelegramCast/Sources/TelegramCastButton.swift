import Foundation
import UIKit
import GoogleCast

// The SDK's own button: it opens the device picker, shows the connection state and offers to
// stop casting while connected. Creating it requires the Cast context.
public final class TelegramCastButton: UIView {
    private let button: GCKUICastButton

    public override init(frame: CGRect) {
        TelegramCastManager.shared.setupIfNeeded()
        self.button = GCKUICastButton(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        self.button.tintColor = .white
        self.button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.addSubview(self.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
