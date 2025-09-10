import SwiftUI
import UIKit

struct ScrollViewOffsetReader: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        DispatchQueue.main.async { context.coordinator.attach(to: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { /* no-op */ }

    final class Coordinator: NSObject {
        private var observation: NSKeyValueObservation?
        private let onChange: (CGFloat) -> Void
        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        func attach(to view: UIView) {
            var s: UIView? = view.superview
            while s != nil, !(s is UIScrollView) { s = s?.superview }
            guard let scroll = s as? UIScrollView else { return }
            observation = scroll.observe(\UIScrollView.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                self?.onChange(max(0, scroll.contentOffset.y))
            }
        }
    }
}

