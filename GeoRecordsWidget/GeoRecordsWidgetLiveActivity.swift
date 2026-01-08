//
//  GeoRecordsWidgetLiveActivity.swift
//  GeoRecordsWidget
//
//  Created by David LaPorte on 12/12/25.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct GeoRecordsWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var emoji: String
    }

    var name: String
}

struct GeoRecordsWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GeoRecordsWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
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

extension GeoRecordsWidgetAttributes {
    fileprivate static var preview: GeoRecordsWidgetAttributes {
        GeoRecordsWidgetAttributes(name: "World")
    }
}

extension GeoRecordsWidgetAttributes.ContentState {
    fileprivate static var smiley: GeoRecordsWidgetAttributes.ContentState {
        GeoRecordsWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: GeoRecordsWidgetAttributes.ContentState {
         GeoRecordsWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: GeoRecordsWidgetAttributes.preview) {
   GeoRecordsWidgetLiveActivity()
} contentStates: {
    GeoRecordsWidgetAttributes.ContentState.smiley
    GeoRecordsWidgetAttributes.ContentState.starEyes
}
