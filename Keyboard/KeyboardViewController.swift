import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private static let height: CGFloat = 330

    private let model = KeyboardModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyTiming.shared.loadedAt = .now
        model.controller = self

        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // Below required so the system can still shrink us during rotation.
        let height = view.heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The system's edge gestures sit on our window and hold back touch-down
        // until the finger lifts, so keys would only light up on release.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        model.didAppear()
        KeyTiming.shared.appeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.stop()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        model.needsGlobe = needsInputModeSwitchKey
        model.hasFullAccess = hasFullAccess
    }
}
