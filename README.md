# GeoRecords

An iOS/iPadOS app that automatically tracks your geographical extremes — furthest north, south, east, west, highest altitude, and furthest from home. Available on the [App Store](https://apps.apple.com/us/app/georecords/id6743328334).

## Features

- **Automatic Record Tracking** — Runs in the background using significant location changes (~500m), detecting new geographical records with zero interaction required
- **Six Record Types** — Furthest North, South, East, West, Up (highest altitude), and Furthest from Home
- **Three Timeframes** — Monthly, Yearly, and All-Time records tracked independently
- **Region Tracking** — Tracks visited US states, countries, and continents with interactive maps
- **Statistics & Charts** — Visualize your geographical history with Swift Charts
- **Photo Integration** — Attach photos to records from your camera or library; scan your photo library to import historical records from geotagged photos
- **iCloud Sync** — Records sync across devices via CloudKit
- **Backup & Restore** — Export/import `.georecords` backup files
- **Home Screen Widgets** — Record and region widgets with map snapshots and photo thumbnails
- **Configurable Notifications** — Get notified when you break records, with per-timeframe controls
- **Metric & Imperial** — Toggle between unit systems for altitude and distance display

## Requirements

- iOS/iPadOS 18.2+
- Location Services (Always authorization for background tracking)

## Architecture

The app follows an MVVM pattern with singleton managers:

- **LocationManager** — Background location tracking via `startMonitoringSignificantLocationChanges()`
- **RecordManager** — In-memory record state with Core Data persistence
- **RecordHistoryManager** — Core Data operations and record history
- **RegionTrackingManager** — State/country/continent visit tracking
- **SettingsManager** — UserDefaults-backed preferences

Built entirely with Apple frameworks — SwiftUI, Core Data, CoreLocation, MapKit, Photos, Charts, WidgetKit, and CloudKit. No third-party dependencies.

## Building

Open `GeoRecords.xcodeproj` in Xcode. The project requires no package resolution or additional setup beyond standard Xcode signing configuration.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
