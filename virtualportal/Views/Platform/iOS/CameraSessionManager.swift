//
//  CameraSessionManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

#if os(iOS)
@preconcurrency import AVFoundation

/// Manages the minimal camera session for enabling camera control interactions
@MainActor
class CameraSessionManager {
    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?

    func startCameraSession() {
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
                } catch {
                    print("CameraControl: failed to create device input: \(error)")
                }

                session.commitConfiguration()
                session.startRunning()

                self?.captureSession = session
                self?.captureDevice = device
            }
        }
    }

    func stopCameraSession() {
        guard let session = captureSession else { return }

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
}
#endif
