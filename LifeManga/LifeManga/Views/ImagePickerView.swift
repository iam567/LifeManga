//
//  ImagePickerView.swift
//  LifeManga
//
//  封装 UIKit 的 UIImagePickerController：
//   - .camera 模式 → 拍照
//   - .photoLibrary 模式 → 单选相册（多选用 PhotosPicker 在 HomeView 里）
//

import SwiftUI
import UIKit

struct ImagePickerView: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onImage: (UIImage, [UIImagePickerController.InfoKey: Any]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onImage(img, info)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
