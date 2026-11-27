import SwiftUI
import UIKit

extension View {
    /// Holds back a swipe-down dismissal of the enclosing sheet while
    /// `isBlocked` returns true, and calls `onAttempt` instead so the sheet can
    /// ask what to do with unsaved edits. `isBlocked` is evaluated at the moment
    /// of the swipe, so it can read state that SwiftUI does not observe.
    func dfkSheetDismissGuard(isBlocked: @escaping () -> Bool, onAttempt: @escaping () -> Void) -> some View {
        background(DFKSheetDismissGuard(isBlocked: isBlocked, onAttempt: onAttempt).frame(width: 0, height: 0))
    }
}

private struct DFKSheetDismissGuard: UIViewControllerRepresentable {
    let isBlocked: () -> Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> GuardController {
        GuardController()
    }

    func updateUIViewController(_ controller: GuardController, context: Context) {
        controller.isBlocked = isBlocked
        controller.onAttempt = onAttempt
        controller.install()
    }

    final class GuardController: UIViewController {
        var isBlocked: () -> Bool = { false }
        var onAttempt: () -> Void = {}
        private var proxy: DelegateProxy?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        /// Wraps the sheet's own presentation delegate (SwiftUI's), forwarding
        /// everything else to it, so the sheet binding still resets on dismiss.
        func install() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let presentation = root.presentationController else { return }
            if let proxy, presentation.delegate === proxy { return }
            let proxy = DelegateProxy(original: presentation.delegate, owner: self)
            self.proxy = proxy
            presentation.delegate = proxy
        }
    }

    final class DelegateProxy: NSObject, UIAdaptivePresentationControllerDelegate {
        let original: UIAdaptivePresentationControllerDelegate?
        weak var owner: GuardController?

        init(original: UIAdaptivePresentationControllerDelegate?, owner: GuardController) {
            self.original = original
            self.owner = owner
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            if owner?.isBlocked() == true { return false }
            return original?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if owner?.isBlocked() == true {
                owner?.onAttempt()
            } else {
                original?.presentationControllerDidAttemptToDismiss?(presentationController)
            }
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            (original?.responds(to: aSelector) ?? false) ? original : super.forwardingTarget(for: aSelector)
        }
    }
}

/// Left screen-edge swipe that calls `onDismiss`; place it in a background of the dismissible screen.
struct DFKEdgeDismissGesture: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> DFKEdgeGestureHostView {
        let view = DFKEdgeGestureHostView()
        view.backgroundColor = .clear
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(in: window)
        }
        return view
    }

    func updateUIView(_ uiView: DFKEdgeGestureHostView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.install(in: uiView.window)
    }

    static func dismantleUIView(_ uiView: DFKEdgeGestureHostView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void
        private weak var installedWindow: UIWindow?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func install(in window: UIWindow?) {
            guard let window, installedWindow !== window else { return }
            uninstall()
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            recognizer.edges = .left
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer { installedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedWindow = nil
        }

        @objc private func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            if translation.x > 80 || velocity.x > 650 {
                onDismiss()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

final class DFKEdgeGestureHostView: UIView {
    var windowDidChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowDidChange?(window)
    }
}
