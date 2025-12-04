# Core Data Model Update Instructions

## Adding Photo Support to GeoRecords

You need to manually update the Core Data model in Xcode to add photo storage capability.

### Steps:

1. **Open Xcode** and load the GeoRecords project

2. **Navigate to the Core Data Model**:
   - In the Project Navigator, find `GeoRecordsModel.xcdatamodeld`
   - Click on it to open the Core Data model editor

3. **Select the RecordHistoryEntry Entity**:
   - In the left sidebar, click on `RecordHistoryEntry`

4. **Add the photoData Attribute**:
   - In the Attributes section, click the `+` button
   - Name the new attribute: `photoData`
   - Type: `Binary Data`
   - Optional: ✅ (checked)
   - Important: Check "Allows External Storage" for efficient handling of large photos

5. **Save the Model**:
   - Press `Cmd+S` to save the changes

6. **Clean and Rebuild**:
   - Menu: Product > Clean Build Folder (Shift+Cmd+K)
   - Menu: Product > Build (Cmd+B)

### What This Does:

The `photoData` attribute will store JPEG image data (compressed to 80% quality) for each record. Photos are:
- Prompted when a new record is broken
- Stored in Core Data with external storage for efficiency
- Displayed in RecordDetailView and HistoryDetailView
- Optional - users can skip taking photos

### Testing:

After building:
1. Run the app on a device or simulator
2. Trigger a record break (adjust location or settings to lower thresholds)
3. You should see a prompt: "🎉 New [Record Type] Record! Capture this moment?"
4. Choose to take a photo, select from library, or skip
5. View the record detail to see the photo displayed above the map

### Notes:

- Existing records without photos will continue to work normally
- The schema change is backward compatible (photoData is optional)
- Photos are compressed to balance quality and storage
