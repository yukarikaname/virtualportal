//
//  CameraControlManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

#if os(iOS)
import AVFoundation
import AudioToolbox
import UIKit

@MainActor
class CameraControlManager: NSObject {
    static let shared = CameraControlManager()
    
    private override init() {
        super.init()
    }
    
    private func performCapture() {
        // Post notification to trigger capture
        NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraCaptureRequested"), object: nil)
        
        // Play shutter sound
        AudioServicesPlaySystemSound(1108) // Camera shutter sound
    }
}
#endif
