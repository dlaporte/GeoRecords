//
//  GeoRecordsWidgetBundle.swift
//  GeoRecordsWidget
//
//  Created by David LaPorte on 12/12/25.
//

import WidgetKit
import SwiftUI

@main
struct GeoRecordsWidgetBundle: WidgetBundle {
    var body: some Widget {
        GeoRecordsWidget()
        SingleRecordWidget()
        RegionStatsWidget()
        RegionMapWidget()
        GeoRecordsWidgetControl()
        GeoRecordsWidgetLiveActivity()
    }
}
