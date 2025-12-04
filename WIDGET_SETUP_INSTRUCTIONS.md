# iOS Widget Setup Instructions

## Creating the GeoRecords Home Screen Widget

The widget code has been created, but you need to manually add a Widget Extension target in Xcode.

### Part 1: Create Widget Extension Target

1. **Open Xcode** with the GeoRecords project

2. **Add Widget Extension**:
   - Menu: File > New > Target...
   - Search for "Widget Extension"
   - Click "Widget Extension" and click "Next"

3. **Configure the Extension**:
   - Product Name: `GeoRecordsWidget`
   - Interface: SwiftUI
   - Include Configuration Intent: ❌ (unchecked - we don't need configuration)
   - Click "Finish"

4. **Activate the Scheme**:
   - When prompted "Activate 'GeoRecordsWidget' scheme?", click "Activate"

5. **Delete the Generated Files**:
   - Xcode creates sample widget files we don't need
   - Delete these files from the GeoRecordsWidget folder:
     - `GeoRecordsWidget.swift` (we'll use our own)
     - `GeoRecordsWidgetBundle.swift` (we'll use our own)
     - `AppIntent.swift` (not needed)

### Part 2: Add Our Widget Files

1. **Add GeoRecordsWidget.swift**:
   - Right-click the `GeoRecordsWidget` folder
   - "Add Files to GeoRecords..."
   - Select `GeoRecordsWidget.swift` from the root directory
   - Make sure "GeoRecordsWidget" target is checked

2. **Configure App Groups** (for data sharing):
   - Select the main GeoRecords target
   - Go to "Signing & Capabilities"
   - Click "+ Capability"
   - Add "App Groups"
   - Enable a group: `group.com.yourname.georecords` (use your actual bundle ID)

   - Repeat for GeoRecordsWidget target:
     - Select GeoRecordsWidget target
     - Add "App Groups" capability
     - Enable the SAME group: `group.com.yourname.georecords`

3. **Share Core Data Files**:
   - Select `PersistenceController.swift` in Project Navigator
   - In File Inspector (right panel), under "Target Membership"
   - Check ✅ both: GeoRecords AND GeoRecordsWidget

   - Repeat for these files:
     - `RecordManager.swift`
     - `SettingsManager.swift`
     - `GeoRecordsModel.xcdatamodeld`

4. **Update PersistenceController** for App Groups:
   - This is already done in the code - it uses the shared App Group container

### Part 3: Build and Test

1. **Clean Build**:
   - Menu: Product > Clean Build Folder (Shift+Cmd+K)

2. **Build the Widget**:
   - Select "GeoRecordsWidget" scheme
   - Build (Cmd+B)

3. **Run the Widget**:
   - Run on simulator or device
   - Long-press on home screen
   - Tap the "+" button (top left)
   - Search for "GeoRecords"
   - Add the widget in your preferred size

### Widget Sizes:

- **Small**: Shows 3 records
- **Medium**: Shows all 7 records
- **Large**: Shows all 7 records with more spacing

### Troubleshooting:

**"No such module 'WidgetKit'"**
- Make sure you're building for iOS 14.0 or later
- Check Deployment Target in project settings

**"Widget shows 'No Records'"**
- Run the main app first to create some records
- Widgets share data via App Groups

**Widget doesn't update**
- Widgets update based on Timeline
- They refresh every 15 minutes automatically
- You can force refresh by long-pressing the widget

### How It Works:

The widget:
1. Reads records from Core Data using shared App Group
2. Displays current records with formatted values
3. Updates every 15 minutes automatically
4. Tapping opens the main app
