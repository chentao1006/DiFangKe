import MapKit
import UIKit

/// A safe MKMapView subclass that prevents its bounds or frame from ever collapsing to 0x0.
/// This prevents iOS 18 Metal rendering assertion crashes when SwiftUI layouts collapse during transitions.
public class SafeMKMapView: MKMapView {
    public var onWindowAppeared: (() -> Void)?
    public var onLayoutSubviews: (() -> Void)?
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onWindowAppeared?()
        }
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}
