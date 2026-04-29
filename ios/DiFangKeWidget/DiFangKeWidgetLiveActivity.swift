//
//  DiFangKeWidgetLiveActivity.swift
//  DiFangKeWidget
//
//  Created by 陈涛 on 2026/4/29.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct DiFangKeWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct DiFangKeWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DiFangKeWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension DiFangKeWidgetAttributes {
    fileprivate static var preview: DiFangKeWidgetAttributes {
        DiFangKeWidgetAttributes(name: "World")
    }
}

extension DiFangKeWidgetAttributes.ContentState {
    fileprivate static var smiley: DiFangKeWidgetAttributes.ContentState {
        DiFangKeWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: DiFangKeWidgetAttributes.ContentState {
         DiFangKeWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: DiFangKeWidgetAttributes.preview) {
   DiFangKeWidgetLiveActivity()
} contentStates: {
    DiFangKeWidgetAttributes.ContentState.smiley
    DiFangKeWidgetAttributes.ContentState.starEyes
}
