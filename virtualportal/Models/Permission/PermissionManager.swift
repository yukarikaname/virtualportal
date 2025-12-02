//
//  PermissionManager.swift
//  virtualportal
//
//  Created on October 20, 2025.
//

import AVFoundation
import Speech
import CoreLocation
import Photos
import UIKit

final class PermissionManager {
    
    // MARK: - Camera
    
    /// Check current camera permission status without requesting
    static func checkCameraPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            completion(status == .authorized)
        }
    }
    
    static func requestCameraPermission(completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
    
    // MARK: - Microphone
    
    /// Check current microphone permission status without requesting
    static func checkMicrophonePermission(completion: @escaping @Sendable (Bool) -> Void) {
        completion(AVAudioApplication.shared.recordPermission == .granted)
    }

    static func requestMicrophonePermission(completion: @escaping @Sendable (Bool) -> Void) {
        let appAudio = AVAudioApplication.shared

        switch appAudio.recordPermission {
        case .granted:
            completion(true)

        case .denied:
            completion(false)

        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }

        @unknown default:
            completion(false)
        }
    }

    // MARK: - Speech Recognition (requires both microphone + speech recognition)
    
    static func checkSpeechRecognitionPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        completion(speechStatus == .authorized)
    }

    /// Synchronous convenience check for both microphone and speech recognition.
    /// Returns a tuple `(microphone: Bool, speechRecognition: Bool)`.
    static func checkPermissions() -> (microphone: Bool, speechRecognition: Bool) {
        let micGranted = AVAudioApplication.shared.recordPermission == .granted
        let speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        return (micGranted, speechGranted)
    }
    
    @MainActor static func requestSpeechRecognitionPermission(completion: @escaping @Sendable (Bool) -> Void) {
        // Only request Speech Recognition permission (SFSpeechRecognizer) here.
        // Do not implicitly request the microphone - that must be requested separately
        // to avoid showing microphone permission UI when only speech recognition is needed.
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { newStatus in
                DispatchQueue.main.async { completion(newStatus == .authorized) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Location
    static func requestLocationPermission(completion: @escaping @Sendable (Bool) -> Void) {
        
        let manager = CLLocationManager()
        let status = manager.authorizationStatus

        switch status {
        case .authorizedWhenInUse:
            completion(true)
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // simple short delay before checking again
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let newStatus = manager.authorizationStatus
                completion(newStatus == .authorizedWhenInUse)
            }
        default:
            completion(false)
        }
    }
    
    // MARK: - Personal Voice
    
    static func requestPersonalVoicePermission(completion: @escaping @Sendable (Bool) -> Void) {
        
        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized)
                }
            }
        case .denied:
            completion(false)
        case .unsupported:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Combined Speech + Personal Voice Flow
    @MainActor private static var didRequestSpeechFlow: Bool = false

    /// Request microphone + speech recognition, then Personal Voice permission if needed.
    /// This method will also refresh `TextToSpeechManager` availability and enable
    /// Personal Voice when available. Completion returns `true` if Personal Voice
    /// is available and enabled, `false` otherwise.
    @MainActor static func requestSpeechAndPersonalVoiceIfNeeded(completion: @escaping @Sendable (Bool) -> Void) {
        // Ensure we only trigger the flow once per app session
        guard !didRequestSpeechFlow else { completion(false); return }
        didRequestSpeechFlow = true

        let perms = checkPermissions()
        if perms.microphone && perms.speechRecognition {
            // We already have mic + speech; request Personal Voice explicitly
            requestPersonalVoicePermission { pvGranted in
                Task { @MainActor in
                    let available = TextToSpeechManager.shared.refreshPersonalVoiceAvailability()
                    TextToSpeechManager.shared.usePersonalVoice = pvGranted && available
                    completion(pvGranted && available)
                }
            }
            return
        }

        // Request microphone first, then speech recognition, then Personal Voice.
        requestMicrophonePermission { micGranted in
            guard micGranted else {
                Task { @MainActor in
                    TextToSpeechManager.shared.usePersonalVoice = false
                    completion(false)
                }
                return
            }

            Task { @MainActor in
                requestSpeechRecognitionPermission { granted in
                    if granted {
                        // After mic+speech granted, request Personal Voice
                        Task { @MainActor in
                            requestPersonalVoicePermission { pvGranted in
                                Task { @MainActor in
                                    let available = TextToSpeechManager.shared.refreshPersonalVoiceAvailability()
                                    TextToSpeechManager.shared.usePersonalVoice = pvGranted && available
                                    completion(pvGranted && available)
                                }
                            }
                        }
                    } else {
                        Task { @MainActor in
                            TextToSpeechManager.shared.usePersonalVoice = false
                            completion(false)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Photo Library (add only)
    static func checkPhotoLibraryAddPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        completion(status == .authorized || status == .limited)
    }

    static func requestPhotoLibraryAddPermission(andSave image: UIImage? = nil, location: CLLocation? = nil, saveAsLivePhoto: Bool = false, completion: @escaping @Sendable (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            if let image = image {
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    if let loc = location {
                        req.location = loc
                    }
                }) { success, error in
                    if let error = error { print("PhotoLibrary save error: \(error)") }
                    completion(success)
                }
            } else {
                completion(true)
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    if let image = image {
                        PHPhotoLibrary.shared().performChanges({
                            let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                            if let loc = location {
                                req.location = loc
                            }
                        }) { success, error in
                            if let error = error { print("PhotoLibrary save error: \(error)") }
                            completion(success)
                        }
                    } else {
                        completion(true)
                    }
                } else {
                    completion(false)
                }
            }
        default:
            completion(false)
        }
    }
}
