import WidgetKit
import SwiftUI

@main
struct DiFangKeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DFKFootprintWidget()
#if canImport(ActivityKit)
        if #available(iOS 18.0, *) {
            TripLiveActivityWidget()
        }
#endif
    }
}
