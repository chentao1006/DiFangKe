import MapKit
import UIKit
import Observation

/// A safe MKMapView subclass that prevents its bounds or frame from ever collapsing to 0x0.
/// This prevents iOS 18 Metal rendering assertion crashes when SwiftUI layouts collapse during transitions.
public class SafeMKMapView: MKMapView {
    public var onWindowAppeared: (() -> Void)?
    public var onLayoutSubviews: (() -> Void)?
    
    private var observesPreferences = false
    private var pageFilter: MKPointOfInterestFilter?
    private var lastStyle = BrowseMapPreferences()
    var updateRouteAppearance: ((BrowseMapPreferences) -> Void)?

    private func observeMapStyle() {
        let style = withObservationTracking {
            BrowseMapSettings.shared.value
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMapStyle() }
        }
        if style.theme != lastStyle.theme || style.places != lastStyle.places {
            preferredConfiguration = style.configuration(defaultFilter: pageFilter)
        }
        if style.scheme != lastStyle.scheme {
            overrideUserInterfaceStyle = style.scheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
        }
        lastStyle = style
        updateRouteAppearance?(style)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if !observesPreferences {
                observesPreferences = true
                pageFilter = pointOfInterestFilter
                observeMapStyle()
            }
            onWindowAppeared?()
        }
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}
