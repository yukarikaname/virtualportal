//
//  CameraSessionManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

#if os(iOS)
@preconcurrency import AVFoundation
import AVKit
import UIKit

/// Manages the minimal camera session for enabling camera control interactions
@MainActor
class CameraSessionManager: NSObject, AVCaptureSessionControlsDelegate {
    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.virtualportal.camera.session")
    private var eventInteraction: AVCaptureEventInteraction?

    func startCameraSession() {
        // Setup AVCaptureEventInteraction FIRST to claim the camera control button
        setupCaptureEventInteraction()
        
        PermissionManager.requestCameraPermission { [weak self] granted in
            guard granted else { return }

            Task { @MainActor in
                let session = AVCaptureSession()
                session.beginConfiguration()

                // Select default wide-angle camera
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    session.commitConfiguration()
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                    }
                    
                    // Add a video data output to actively use the camera
                    // This prevents iOS from launching the system camera app
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    if session.canAddOutput(videoOutput) {
                        session.addOutput(videoOutput)
                        print("CameraControl: Added video output to session")
                    }
                } catch {
                    print("CameraControl: failed to create device input: \(error)")
                }

                session.commitConfiguration()
                session.startRunning()

                self?.captureSession = session
                self?.captureDevice = device

                // Configure Camera Control session controls (zoom, exposure, and a simple capture action)
                self?.configureCaptureControlsIfNeeded()
            }
        }
    }
    
    // MARK: - Capture Event Interaction
    private func setupCaptureEventInteraction() {
        // Prevent duplicate setup
        guard eventInteraction == nil else {
            print("CameraControl: event interaction already set up")
            return
        }
        
        // Create event interaction to handle camera control button presses
        let interaction = AVCaptureEventInteraction { event in
            Task { @MainActor in
                print("CameraControl: event received - phase: \(event.phase.rawValue)")
                switch event.phase {
                case .began:
                    print("CameraControl: capture button pressed")
                case .ended:
                    print("CameraControl: capture button released - triggering capture")
                    NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraCaptureRequested"), object: nil)
                case .cancelled:
                    print("CameraControl: capture button cancelled")
                @unknown default:
                    break
                }
            }
        }
        
        // CRITICAL: Enable before adding to window
        interaction.isEnabled = true
        self.eventInteraction = interaction
        
        // Add interaction to the key window immediately
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
                window.addInteraction(interaction)
                print("CameraControl: AVCaptureEventInteraction added and enabled on window: \(window)")
            } else {
                print("CameraControl: WARNING - No window found to add interaction")
            }
        }
    }

    // MARK: - Capture Controls
    private func configureCaptureControlsIfNeeded() {
        guard let session = captureSession, let device = captureDevice else { return }

        // Ensure host supports controls
        guard session.supportsControls else { return }

        session.beginConfiguration()

        // Remove any previously configured controls
        for control in session.controls {
            session.removeControl(control)
        }

        // Create standard system controls for zoom and exposure
        let zoomControl = AVCaptureSystemZoomSlider(device: device) { zoomFactor in
            // Called on main actor by design; update UI or state as needed
            let displayZoom = device.displayVideoZoomFactorMultiplier * zoomFactor
            // Currently we just log; UI updates should be done on main
            Task { @MainActor in
                print("CameraControl: zoom changed -> \(displayZoom)")
            }
        }

        let exposureControl = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            // Apply exposure bias to the device on the session queue
            self?.sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    device.setExposureTargetBias(bias) { _ in }
                    device.unlockForConfiguration()
                } catch {
                    print("CameraControl: unable to set exposure bias: \(error)")
                }
            }
        }

        // Create a simple index picker to act as a capture action trigger
        let captureTitles = [NSLocalizedString("Capture", comment: "Capture action")]
        let capturePicker = AVCaptureIndexPicker("Capture", symbolName: "camera.fill", localizedIndexTitles: captureTitles)

        // Add supported controls to the session
        let controlsToAdd: [AVCaptureControl] = [zoomControl, exposureControl, capturePicker]
        for control in controlsToAdd {
            if session.canAddControl(control) {
                session.addControl(control)
            } else {
                print("CameraControl: unable to add control: \(control)")
            }
        }

        // Set delegate to receive presentation/activation callbacks
        session.setControlsDelegate(self, queue: DispatchQueue.main)

        session.commitConfiguration()
    }

    // MARK: - AVCaptureSessionControlsDelegate
    public func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        Task { @MainActor in
            print("CameraControl: session controls became active")
            // Optionally hide overlay UI to focus on control interaction
            NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraControlsActive"), object: nil)
        }
    }

    public func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in
            print("CameraControl: will enter fullscreen appearance")
            NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraControlsWillEnterFullscreen"), object: nil)
        }
    }

    public func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in
            print("CameraControl: will exit fullscreen appearance")
            NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraControlsWillExitFullscreen"), object: nil)
        }
    }

    public func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        Task { @MainActor in
            print("CameraControl: session controls became inactive")
            NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraControlsInactive"), object: nil)
        }
    }

    func stopCameraSession() {
        guard let session = captureSession else { return }
        
        // Remove event interaction
        if let interaction = eventInteraction,
           let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.removeInteraction(interaction)
        }
        eventInteraction = nil

        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()

            // Remove inputs
            for input in session.inputs {
                session.removeInput(input)
            }

            DispatchQueue.main.async {
                self.captureSession = nil
                self.captureDevice = nil
            }
        }
    }
    
    // MARK: - AVCaptureEventInteractionDelegate
    @objc func eventInteraction(_ interaction: AVCaptureEventInteraction, didOutput event: AVCaptureEvent) {
        // Handle camera control events
        Task { @MainActor in
            print("CameraControl: event interaction received event")
        }
    }
}
#endif
