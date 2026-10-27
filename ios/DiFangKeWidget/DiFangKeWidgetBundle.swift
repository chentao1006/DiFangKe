import WidgetKit
import SwiftUI

@main
struct DiFangKeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DFKFootprintWidget()
#if canImport(ActivityKit)
        currentTrackingWidget()
        tripProgressWidget()
#endif
    }

    private func currentTrackingWidget() -> some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildBlock(CurrentTrackingLiveActivityWidget())
        } else {
            return WidgetBundleBuilder.buildBlock(LegacyCurrentTrackingLiveActivityWidget())
        }
    }

    private func tripProgressWidget() -> some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildBlock(TripProgressLiveActivityWidget())
        } else {
            return WidgetBundleBuilder.buildBlock(LegacyTripProgressLiveActivityWidget())
        }
    }
}
