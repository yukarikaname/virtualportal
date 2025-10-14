//
//  PermissionManager.swift
//  virtualportal
//
//  Created on October 20, 2025.
//

import AVFoundation
import Speech
import CoreLocation

final class PermissionManager {
    
    // MARK: - Camera
    
    /// Check current camera permission status without requesting
    static func checkCameraPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        completion(status == .authorized)
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
        switch AVAudioApplication.shared.recordPermission {
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
    
    /// Check current speech recognition permission status without requesting
    static func checkSpeechRecognitionPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let micPermission = AVAudioApplication.shared.recordPermission == .granted
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        completion(micPermission && speechStatus == .authorized)
    }
    
    static func requestSpeechRecognitionPermission(completion: @escaping @Sendable (Bool) -> Void) {
        // First request microphone permission
        requestMicrophonePermission { micGranted in
            guard micGranted else {
                completion(false)
                return
            }
            
            // Then request speech recognition permission
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized:
                completion(true)
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    DispatchQueue.main.async {
                        completion(newStatus == .authorized)
                    }
                }
            default:
                completion(false)
            }
        }
    }

    // MARK: - Location
    static func requestLocationPermission(completion: @escaping @Sendable (Bool) -> Void) {
        #if os(iOS)
        let manager = CLLocationManager()
        let status = manager.authorizationStatus  // ✅ modern API (iOS 14+)

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // simple short delay before checking again
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let newStatus = manager.authorizationStatus
                completion(newStatus == .authorizedAlways || newStatus == .authorizedWhenInUse)
            }
        default:
            completion(false)
        }
        #else
        // visionOS doesn't support location services
        completion(false)
        #endif
    }
}
