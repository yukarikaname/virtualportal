//
//  PermissionViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/20/25.
//

import Foundation
import Combine
import SwiftUI
import CoreLocation
import AVFAudio

@MainActor
public class PermissionViewModel: ObservableObject {

    // MARK: - Published
    @Published public var cameraPermissionGranted: Bool = false
    @Published public var speechPermissionGranted: Bool = false
    @Published public var personalVoiceGranted: Bool = false
    @Published public var photoLibraryGranted: Bool = false
    @Published public var locationGranted: Bool = false

    // MARK: - Initialization
    public init() {
        checkExistingPermissions()
    }

    // MARK: - Checks
    public func checkExistingPermissions() {
        PermissionManager.checkCameraPermission { granted in
            Task { @MainActor in self.cameraPermissionGranted = granted }
        }

        PermissionManager.checkSpeechRecognitionPermission { granted in
            Task { @MainActor in self.speechPermissionGranted = granted }
        }

        let pvStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        Task { @MainActor in
            self.personalVoiceGranted = (pvStatus == .authorized)
        }

        PermissionManager.checkPhotoLibraryAddPermission { granted in
            Task { @MainActor in self.photoLibraryGranted = granted }
        }

        let locStatus = CLLocationManager().authorizationStatus
        Task { @MainActor in
            #if os(visionOS)
            self.locationGranted = (locStatus == .authorizedWhenInUse)
            #else
            self.locationGranted = (locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways)
            #endif
        }
    }

    // MARK: - Requests
    public func requestCameraPermission() {
        PermissionManager.requestCameraPermission { granted in
            Task { @MainActor in self.cameraPermissionGranted = granted }
        }
    }

    public func requestSpeechPermission() {
        PermissionManager.requestSpeechRecognitionPermission { granted in
            Task { @MainActor in self.speechPermissionGranted = granted }
        }
    }

    public func requestPersonalVoicePermission() {
        PermissionManager.requestPersonalVoicePermission { granted in
            Task { @MainActor in self.personalVoiceGranted = granted }
        }
    }

    public func requestPhotoLibraryAddPermission(andSave image: UIImage? = nil, location: CLLocation? = nil, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        PermissionManager.requestPhotoLibraryAddPermission(andSave: image, location: location) { success in
            Task { @MainActor in self.photoLibraryGranted = success; completion(success) }
        }
    }

    public func requestLocationPermission(completion: (@Sendable (Bool) -> Void)? = nil) {
        PermissionManager.requestLocationPermission { granted in
            Task { @MainActor in
                self.locationGranted = granted
                completion?(granted)
            }
        }
    }
}
