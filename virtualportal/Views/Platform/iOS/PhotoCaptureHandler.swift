//
//  PhotoCaptureHandler.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

#if os(iOS)
import UIKit
import Photos

/// Handles photo capture, processing, and sharing
@MainActor
class PhotoCaptureHandler {
    @MainActor
    func handleCapture(image: UIImage) async -> (thumbnail: UIImage?, fullImage: UIImage?) {
        // Create square thumbnail for display (no black bars)
        let thumbnail = cropToSquare(image: image)
        return (thumbnail, image)
    }

    @MainActor
    private func cropToSquare(image: UIImage) -> UIImage {
        let originalWidth = image.size.width
        let originalHeight = image.size.height
        let minDimension = min(originalWidth, originalHeight)

        let cropRect = CGRect(
            x: (originalWidth - minDimension) / 2,
            y: (originalHeight - minDimension) / 2,
            width: minDimension,
            height: minDimension
        )

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    func saveToPhotoLibrary(image: UIImage, location: CLLocation?) async {
        // Delegate photo permission checks and save logic to PermissionManager, passing location metadata (may be nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PermissionManager.requestPhotoLibraryAddPermission(andSave: image, location: location) { success in
                if !success {
                    print("PhotoLibrary: permission denied or save failed")
                }
                cont.resume()
            }
        }
    }

    func shareImage(image: UIImage) {
        let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = topVC.view
            pop.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        topVC.present(activityVC, animated: true)
    }
}
#endif