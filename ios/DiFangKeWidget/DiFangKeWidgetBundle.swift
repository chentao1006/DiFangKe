import WidgetKit
import SwiftUI

@main
struct DiFangKeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DFKFootprintWidget()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            TripLiveActivityWidget()
        }
#endif
    }
}
