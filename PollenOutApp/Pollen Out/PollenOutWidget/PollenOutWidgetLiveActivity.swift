//
//  PollenOutWidgetLiveActivity.swift
//  PollenOutWidget
//
//  Created by John Weatherford on 3/14/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct PollenOutWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct PollenOutWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PollenOutWidgetAttributes.self) { context in
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

extension PollenOutWidgetAttributes {
    fileprivate static var preview: PollenOutWidgetAttributes {
        PollenOutWidgetAttributes(name: "World")
    }
}

extension PollenOutWidgetAttributes.ContentState {
    fileprivate static var smiley: PollenOutWidgetAttributes.ContentState {
        PollenOutWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: PollenOutWidgetAttributes.ContentState {
         PollenOutWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: PollenOutWidgetAttributes.preview) {
   PollenOutWidgetLiveActivity()
} contentStates: {
    PollenOutWidgetAttributes.ContentState.smiley
    PollenOutWidgetAttributes.ContentState.starEyes
}
