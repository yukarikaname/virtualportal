//
//  ModelLayerView+State.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

#if os(iOS)
import SwiftUI
import AVFoundation

extension ModelLayerView {
    // MARK: - Permission Checking

    func checkAndShowPermissionSheet() {
        Task { @MainActor in
            // Use synchronous checks to avoid mutating main-actor state from Sendable closures
            let cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let perms = PermissionManager.checkPermissions()

            // The sheet only requires Camera + Speech Recognition to be granted.
            // Microphone is optional here because the PermissionSheet requests Speech Recognition
            // and not Microphone explicitly — the microphone will be requested by the speech flow
            // when needed. Align the initial check with the sheet's required permissions.
            if !cameraAuthorized || !perms.speechRecognition {
                showPermissionSheet = true
            }
        }
    }
}
#endif