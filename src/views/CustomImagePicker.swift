//
//  CustomImagePicker.swift
//
//  iOS 15 上没有 SwiftUI 的 PhotosPicker（那个要 iOS 16+），所以自己包一层 PHPickerViewController。
//
//  为什么用 PHPicker 而不是老的 UIImagePickerController：
//    PHPicker 跑在**系统自己的进程**里，选完把图拷给我们 ——
//    所以**不需要相册权限**，不弹权限框，也不用依赖 Info.plist 的相册描述。
//

import SwiftUI
import PhotosUI

struct CustomImagePicker: UIViewControllerRepresentable {

    /// 选完之后回调（已经在主线程上）
    let onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let onPicked: (UIImage) -> Void

        init(onPicked: @escaping (UIImage) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                return
            }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    self.onPicked(image)
                }
            }
        }
    }
}
