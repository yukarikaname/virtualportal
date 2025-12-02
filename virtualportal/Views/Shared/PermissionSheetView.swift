//
//  PermissionSheetView.swift
//  virtualportal
//
//  Created on November 23, 2025.
//

import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import UIKit
import Photos

/// A sheet view that requests essential permissions (Camera & Speech Recognition)
/// and optional permission (Personal Voice).
/// The sheet cannot be dismissed without granting all essential permissions.
struct PermissionSheetView: View {
    @Binding var isPresented: Bool
    
    @State private var cameraGranted: Bool = false
    @State private var speechGranted: Bool = false
    @State private var personalVoiceGranted: Bool = false
    @State private var photoLibraryGranted: Bool = false
    @State private var locationGranted: Bool = false
    
    @State private var cameraRequested: Bool = false
    @State private var speechRequested: Bool = false
    @State private var personalVoiceRequested: Bool = false
    @State private var photoLibraryRequested: Bool = false
    @State private var locationRequested: Bool = false
    
    private var allEssentialPermissionsGranted: Bool {
        cameraGranted && speechGranted
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue.gradient)
                    
                    Text("Permissions Required")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("We need a few permissions to provide basic functionality")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 20)
                
                // Permission List: use a `Form` with grouped `Sections` to match SettingsView visual style
                Form {
                    Section(header: Text("Essential")) {
                        PermissionRow(
                            icon: "camera.fill",
                            title: "Camera",
                            description: "Required for AR and visual interaction",
                            isGranted: cameraGranted,
                            isEssential: true,
                            action: requestCamera
                        )
                        PermissionRow(
                            icon: "waveform",
                            title: "Speech Recognition",
                            description: "Required for voice conversation",
                            isGranted: speechGranted,
                            isEssential: true,
                            action: requestSpeech
                        )
                    }
                    Section(header: Text("Optional")) {
                        PermissionRow(
                            icon: "person.wave.2.fill",
                            title: "Personal Voice",
                            description: "Use personal voice for responses",
                            isGranted: personalVoiceGranted,
                            isEssential: false,
                            action: requestPersonalVoice
                        )
#if os(iOS)
                        PermissionRow(
                            icon: "photo.on.rectangle.angled",
                            title: "Photo Library",
                            description: "Allow saving captured photos to your library",
                            isGranted: photoLibraryGranted,
                            isEssential: false,
                            action: requestPhotoLibrary
                        )
#endif
                        PermissionRow(
                            icon: "location.fill",
                            title: "Location",
                            description: "Save location metadata with captured photos",
                            isGranted: locationGranted,
                            isEssential: false,
                            action: requestLocationPermission
                        )
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                
                Spacer()
                
                // Continue Button
                Button(action: {
                    if allEssentialPermissionsGranted {
                        isPresented = false
                    }
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!allEssentialPermissionsGranted)
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!allEssentialPermissionsGranted)
        }
        .onAppear {
            checkExistingPermissions()
        }
    }
    
    // MARK: - Permission Checking
    
    private func checkExistingPermissions() {
        // Check Camera
        PermissionManager.checkCameraPermission { granted in
            Task { @MainActor in
                cameraGranted = granted
                cameraRequested = granted
            }
        }
        
        // Check Speech Recognition
        PermissionManager.checkSpeechRecognitionPermission { granted in
            Task { @MainActor in
                speechGranted = granted
                speechRequested = granted
            }
        }
        
        // Check Personal Voice
        let pvStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        Task { @MainActor in
            personalVoiceGranted = (pvStatus == .authorized)
            personalVoiceRequested = (pvStatus != .notDetermined)
        }

        // Check Photo Library (add only)
        PermissionManager.checkPhotoLibraryAddPermission { granted in
            Task { @MainActor in
                photoLibraryGranted = granted
                photoLibraryRequested = granted
            }
        }

        // Check Location authorization
        #if os(iOS)
        let locStatus = CLLocationManager().authorizationStatus
        Task { @MainActor in
            locationGranted = (locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways)
            locationRequested = (locStatus != .notDetermined)
        }
        #endif
    }
    
    // MARK: - Permission Requests
    
    private func requestCamera() {
        guard !cameraRequested else { return }
        cameraRequested = true
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            Task { @MainActor in cameraGranted = true }
        case .notDetermined:
            PermissionManager.requestCameraPermission { granted in
                Task { @MainActor in cameraGranted = granted }
            }
        default:
            // .denied or .restricted — open Settings so user can enable
            openAppSettings()
        }
    }
    
    private func requestSpeech() {
        guard !speechRequested else { return }
        speechRequested = true
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            Task { @MainActor in speechGranted = true }
        case .notDetermined:
            PermissionManager.requestSpeechRecognitionPermission { granted in
                Task { @MainActor in speechGranted = granted }
            }
        default:
            // Denied or restricted
            openAppSettings()
        }
    }
    
    private func requestPersonalVoice() {
        guard !personalVoiceRequested else { return }
        personalVoiceRequested = true
        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        switch status {
        case .authorized:
            Task { @MainActor in personalVoiceGranted = true }
        case .notDetermined:
            PermissionManager.requestPersonalVoicePermission { granted in
                Task { @MainActor in
                    personalVoiceGranted = granted
                    if granted {
                        let available = TextToSpeechManager.shared.refreshPersonalVoiceAvailability()
                        TextToSpeechManager.shared.usePersonalVoice = granted && available
                    }
                }
            }
        default:
            openAppSettings()
        }
    }

    private func requestLocationPermission() {
        guard !locationRequested else { return }
        locationRequested = true

        let status = CLLocationManager().authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            Task { @MainActor in
                locationGranted = true
            }
        case .notDetermined:
            PermissionManager.requestLocationPermission { granted in
                Task { @MainActor in
                    locationGranted = granted
                }
            }
        default:
            openAppSettings()
        }
    }

    private func requestPhotoLibrary() {
        guard !photoLibraryRequested else { return }
        photoLibraryRequested = true

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            Task { @MainActor in photoLibraryGranted = true }
        case .notDetermined:
            PermissionManager.requestPhotoLibraryAddPermission(andSave: nil) { granted in
                Task { @MainActor in photoLibraryGranted = granted }
            }
        default:
            openAppSettings()
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Permission Row Component

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let isEssential: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Icon - use accent color similar to SettingsView
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 30)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Status/Action
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Button(action: action) {
                    Text("Grant")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

#Preview {
    PermissionSheetView(isPresented: .constant(true))
}
