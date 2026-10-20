import WidgetKit
import SwiftUI

@main
struct DiFangKeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DFKFootprintWidget()
#if canImport(ActivityKit)
        currentTrackingWidget()
#endif
    }

    private func currentTrackingWidget() -> some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildBlock(CurrentTrackingLiveActivityWidget())
        } else {
            return WidgetBundleBuilder.buildBlock(LegacyCurrentTrackingLiveActivityWidget())
        }
    }
}
