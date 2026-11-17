// Swipe from the left edge to go back, on every pushed page.
//
// Every screen hides the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) to draw its own
// header, and UIKit switches the interactive pop gesture off along with the bar. Re-enable it for
// every stack: the gesture may begin whenever there is a page to go back to.

import UIKit

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        return viewControllers.count > 1
    }
}
