import SwiftUI
import UIKit

/// The touch surface under the HUD, in UIKit so the touches can be told apart the way a video player
/// needs: a tap (toggles the HUD) waits for a double tap and a press and hold to fail; a double tap
/// steps back or ahead; a press and hold on the left or right third plays at 2x while held; a one-finger
/// drag is decided once it has moved (PhonePlayerTouch.drag): sideways scrubs, up / down sets the
/// brightness (left half) or the volume (right half), down from the middle pulls the player away; a
/// pinch fills or fits the picture.
struct PhonePlayerStage: UIViewRepresentable {
    struct Handlers {
        var tap: () -> Void = {}
        var doubleTap: (_ x: CGFloat, _ width: CGFloat) -> Void = { _, _ in }
        /// A hold began (true) or ended (false) at x of width.
        var hold: (_ on: Bool, _ x: CGFloat, _ width: CGFloat) -> Void = { _, _, _ in }
        /// The drag kind once decided, then its moves; `ended` with the velocity.
        var dragBegan: (_ kind: PhonePlayerTouch.Drag) -> Void = { _ in }
        var dragMoved: (_ kind: PhonePlayerTouch.Drag, _ translation: CGSize, _ size: CGSize) -> Void = { _, _, _ in }
        var dragEnded: (_ kind: PhonePlayerTouch.Drag, _ translation: CGSize, _ velocity: CGPoint, _ size: CGSize) -> Void = { _, _, _, _ in }
        var pinched: (_ scale: CGFloat) -> Void = { _ in }
    }

    var isLive: Bool
    var handlers: Handlers

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator
        c.view = v

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = PhonePlayerTouch.holdAfter
        hold.allowableMovement = PhonePlayerTouch.decideAfter
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        single.require(toFail: double)
        single.require(toFail: hold)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        for g in [double, hold, single, pan, pinch] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        c.pan = pan
        c.pinch = pinch
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.handlers = handlers
        context.coordinator.isLive = isLive
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var handlers = Handlers()
        var isLive = false
        weak var view: UIView?
        weak var pan: UIPanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        private var drag: PhonePlayerTouch.Drag = .undecided
        private var dragStartX: CGFloat = 0
        private var holding = false

        private var size: CGSize { view?.bounds.size ?? .zero }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            handlers.tap()
        }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            handlers.doubleTap(g.location(in: view).x, size.width)
        }

        @objc func held(_ g: UILongPressGestureRecognizer) {
            let x: CGFloat = g.location(in: view).x
            switch g.state {
            case .began:
                holding = PhonePlayerTouch.holdSpeedsUp(x: x, width: size.width)
                if holding { handlers.hold(true, x, size.width) }
            case .ended, .cancelled, .failed:
                if holding { handlers.hold(false, x, size.width) }
                holding = false
            default: break
            }
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            let t: CGPoint = g.translation(in: view)
            let translation = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began:
                dragStartX = g.location(in: view).x - t.x
                drag = .undecided
                decide(translation)
            case .changed:
                if drag == .undecided { decide(translation) }
                if drag != .undecided { handlers.dragMoved(drag, translation, size) }
            case .ended, .cancelled, .failed:
                if drag != .undecided {
                    let v: CGPoint = g.state == .ended ? g.velocity(in: view) : .zero
                    handlers.dragEnded(drag, g.state == .ended ? translation : .zero, v, size)
                }
                drag = .undecided
            default: break
            }
        }

        private func decide(_ translation: CGSize) {
            let d = PhonePlayerTouch.drag(startX: dragStartX, width: size.width, translation: translation, isLive: isLive)
            guard d != .undecided else { return }
            drag = d
            handlers.dragBegan(d)
            handlers.dragMoved(d, translation, size)
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard g.state == .ended else { return }
            handlers.pinched(g.scale)
        }

        /// A pinch takes over from a drag that its first finger started.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g === pinch && other === pan) || (g === pan && other === pinch)
        }
    }
}
