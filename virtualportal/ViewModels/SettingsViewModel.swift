//
//  SettingsViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine
import SwiftUI
import RealityKit
import ARKit
import MLXLMCommon

/// ViewModel for app settings
/// Manages user preferences and configuration
@MainActor
public class SettingsViewModel: ObservableObject {
    
    // MARK: - General Settings
    @AppStorage("usdzModelName") public var usdzModelName: String = ""
    @AppStorage("characterPersonality") public var characterPersonality: String = ""
    // Extra prompt for LLM
    @AppStorage("extraLLMPrompt") public var extraLLMPrompt: String = ""
    @AppStorage("modelScale") public var modelScale: Double = 1.0
    
    // MARK: - Advanced Settings
    @AppStorage("arResolution") public var arResolution: String = "1920x1080"
    @AppStorage("arFrameRate") public var arFrameRate: Int = 60
    @AppStorage("vlmInterval") public var vlmInterval: Double = 5.0
    @AppStorage("vlmDownscaleResolution") public var vlmDownscaleResolution: Bool = true
    @AppStorage("applyCustomShader") public var applyCustomShader: Bool = false
    @AppStorage("objectOcclusionEnabled") public var objectOcclusionEnabled: Bool = true
    
    // MARK: - TTS Settings
    @AppStorage("autoCommentaryEnabled") public var autoCommentaryEnabled: Bool = true
    @AppStorage("autoInterruptEnabled") public var autoInterruptEnabled: Bool = true
    @AppStorage("speechRate") public var speechRate: Double = 0.5
    
    // MARK: - State
    @Published public var isImporting: Bool = false
    @Published public var importError: String?
    @Published public var isGeneratingDescription: Bool = false
    
    // MARK: - VLM Model
    private var vlmModel = FastVLMModel()
    @Published public var vlmLoaded: Bool = false
    
    // MARK: - Constants
    public let defaultPrompt = ""
    
    // MARK: - Initialization
    public init() {
        // Do not automatically load the VLM model here to avoid expensive work
        // during onboarding or when a SettingsViewModel is created transiently.
        // Call `loadVLMModel()` explicitly when the app is ready to start VLM.

        verifyModelFile()
    }

    /// Explicitly start loading the VLM model. This is async and should be
    /// called from a Task context (e.g. `Task { await settingsViewModel.loadVLMModel() }`).
    public func loadVLMModel() async {
        await vlmModel.load()
        vlmLoaded = vlmModel.isModelLoaded
    }
    
    private func verifyModelFile() {
        guard !usdzModelName.isEmpty else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        let modelURL = modelsPath.appendingPathComponent(usdzModelName)
        
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            print("Stored model '\(usdzModelName)' not found at path: \(modelURL.path)")
            // Clear the invalid model name
            usdzModelName = ""
        } else {
            // Found model file
        }
    }
    
    
    // MARK: - Model Import
    
    public func importModel(from url: URL) {
        isImporting = true
        importError = nil
        
        Task {
            do {
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    throw NSError(domain: "SettingsViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot access file"])
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
                
                try FileManager.default.createDirectory(at: modelsPath, withIntermediateDirectories: true)
                
                let fileName = url.lastPathComponent
                let destURL = modelsPath.appendingPathComponent(fileName)
                
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                
                // Copy the file
                try FileManager.default.copyItem(at: url, to: destURL)
                
                // Verify the file was copied successfully
                guard FileManager.default.fileExists(atPath: destURL.path) else {
                    throw NSError(domain: "SettingsViewModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "File copy verification failed"])
                }
                
                await MainActor.run {
                    self.usdzModelName = fileName
                    self.isImporting = false
                    print("Model imported successfully: \(fileName)")
                }
            } catch {
                await MainActor.run {
                    self.importError = "Import failed: \(error.localizedDescription)"
                    self.isImporting = false
                    print("Model import failed: \(error)")
                }
            }
        }
    }
    
    // MARK: - Notification
    
    public func notifyARConfigurationChanged() {
        NotificationCenter.default.post(name: Notification.Name("virtualportal.arConfigurationChanged"), object: nil)
    }
}

