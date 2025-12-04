import SwiftUI
import PhotosUI

/// SwiftUI wrapper for taking photos or selecting from library when breaking records
struct PhotoPicker: View {
    let recordType: String
    let onPhotoSelected: (Data?) -> Void
    let onDismiss: () -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSourceChoice = true

    var body: some View {
        VStack(spacing: 20) {
            if showSourceChoice {
                Text("🎉 New \(recordType) Record!")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Capture this moment?")
                    .font(.headline)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    Button(action: {
                        showSourceChoice = false
                        showCamera = true
                    }) {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }

                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }

                    Button(action: {
                        onPhotoSelected(nil)
                        onDismiss()
                    }) {
                        Text("Skip")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data),
                   let compressedData = uiImage.jpegData(compressionQuality: 0.7) {
                    onPhotoSelected(compressedData)
                } else {
                    onPhotoSelected(nil)
                }
                onDismiss()
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                if let image = image,
                   let data = image.jpegData(compressionQuality: 0.7) {
                    onPhotoSelected(data)
                } else {
                    onPhotoSelected(nil)
                }
                onDismiss()
            }
        }
    }
}

/// UIKit wrapper for camera access
struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.originalImage] as? UIImage
            onImagePicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImagePicked(nil)
        }
    }
}
