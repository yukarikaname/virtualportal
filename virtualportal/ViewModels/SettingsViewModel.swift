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
    @AppStorage("promptText") public var promptText: String = "Black hair girl with brown eyes, wearing a futuristic outfit, standing in a neon-lit cityscape at night."
    @AppStorage("saveLocationEnabled") public var saveLocationEnabled: Bool = false
    @AppStorage("livePhotoEnabled") public var livePhotoEnabled: Bool = false
    @AppStorage("modelScale") public var modelScale: Double = 1.0
    
    // MARK: - Advanced Settings
    @AppStorage("arResolution") public var arResolution: String = "1920x1080"
    @AppStorage("arFrameRate") public var arFrameRate: Int = 60
    @AppStorage("arHDREnabled") public var arHDREnabled: Bool = true
    @AppStorage("vlmInterval") public var vlmInterval: Double = 5.0
    @AppStorage("vlmDownscaleResolution") public var vlmDownscaleResolution: Bool = true
    @AppStorage("vlmPrompt") public var vlmPrompt: String = "Describe what you see in this scene in English."
    @AppStorage("vlmPromptSuffix") public var vlmPromptSuffix: String = "Output should be brief, about 15 words or less."
    @AppStorage("applyCustomShader") public var applyCustomShader: Bool = false
    @AppStorage("objectOcclusionEnabled") public var objectOcclusionEnabled: Bool = true
    
    // MARK: - TTS Settings
    @AppStorage("usePersonalVoice") public var usePersonalVoice: Bool = false
    
    // MARK: - State
    @Published public var isImporting: Bool = false
    @Published public var importError: String?
    @Published public var isGeneratingDescription: Bool = false
    
    // MARK: - VLM Model
    private var vlmModel = FastVLMModel()
    
    // MARK: - Constants
    public let defaultPrompt = "Black hair girl with brown eyes, wearing a futuristic outfit, standing in a neon-lit cityscape at night."
    
    // MARK: - Initialization
    public init() {
        Task {
            await vlmModel.load()
        }
        
    verifyModelFile()
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
    
    // MARK: - Reset Methods
    
    public func resetVLMSettings() {
        vlmInterval = 5.0
        vlmDownscaleResolution = true
        vlmPrompt = "Describe what you see in this scene in English."
        vlmPromptSuffix = "Output should be brief, about 15 words or less."
    }
    
    public func resetARSettings() {
        arResolution = "1920x1080"
        arFrameRate = 60
        arHDREnabled = true
    }
    
    public func resetAllSettings() {
        resetVLMSettings()
        resetARSettings()
        modelScale = 1.0
        applyCustomShader = false
        objectOcclusionEnabled = true
        saveLocationEnabled = false
        livePhotoEnabled = false
        promptText = defaultPrompt
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
        NotificationCenter.default.post(name: .arConfigurationChanged, object: nil)
    }
    
    // MARK: - Generate Description
    
    public func generateDescription(supportsModelRendering: Bool) {
        guard supportsModelRendering, !usdzModelName.isEmpty else { return }
        
        isGeneratingDescription = true
        
        Task {
            #if os(iOS)
            do {
                // Render the USDZ model to an image (isolated, no environment)
                guard let modelImage = await renderUSDZToImage(modelName: usdzModelName),
                      let ciImage = CIImage(image: modelImage) else {
                    isGeneratingDescription = false
                    return
                }
                
                // Create optimized prompt for VLM - focus ONLY on character model
                let prompt = """
                You are viewing a 3D character model rendered in isolation. The background is IRRELEVANT - it's just a rendering backdrop.
                
                Describe ONLY the 3D character model with these specific details:
                - Hair: exact color, length, style
                - Eyes: specific color
                - Face: shape, features (nose, lips, eyebrows)
                - Skin tone
                - Outfit: complete description with colors, materials, style
                - Accessories: jewelry, glasses, hats, etc.
                - Body type and proportions
                - Any distinctive features
                
                IMPORTANT: Do NOT mention the background, environment, or rendering context. Focus exclusively on the character model itself.
                """
                
                let suffix = "Write naturally and descriptively in 35-45 words. Character details only - no background."
                
                // Create user input
                let userInput = UserInput(
                    prompt: .text("\(prompt) \(suffix)"),
                    images: [.ciImage(ciImage)]
                )
                
                // Generate description
                let task = await vlmModel.generate(userInput)
                await task.value
                
                // Update prompt text
                promptText = vlmModel.output
            }
            #else
            // Model rendering not supported on this platform
            #endif
            
            isGeneratingDescription = false
        }
    }
    
    #if os(iOS)
    private func renderUSDZToImage(modelName: String) async -> UIImage? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        let modelURL = modelsPath.appendingPathComponent(modelName)
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("Model file not found: \(modelURL.path)")
            return nil
        }
        
        // Load the model entity first
        guard let entity = try? await ModelEntity(contentsOf: modelURL) else {
            print("Failed to load model entity")
            return nil
        }
        
        // Calculate optimal scale to fit model in a standard view
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        let targetSize: Float = 1.0
        let scale = maxDimension > 0 ? targetSize / maxDimension : 1.0
        entity.scale = SIMD3<Float>(repeating: scale)
        
        // Center the model
        entity.position = [0, -bounds.center.y * scale, -2.0]
        
        // Create anchors for the model and lighting
        let anchor = AnchorEntity(world: [0, 0, 0])
        anchor.addChild(entity)
        
        // Add lighting to illuminate the model
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 2000
        directionalLight.light.color = .white
        directionalLight.orientation = simd_quatf(angle: -.pi / 6, axis: [1, -0.5, 0])
        
        let lightAnchor = AnchorEntity(world: [0, 0, 0])
        lightAnchor.position = [0, 1, 0]
        lightAnchor.addChild(directionalLight)
        
        // Create a temporary view ONLY for rendering (isolated, no AR) on main thread
        let renderView = await MainActor.run {
            ARView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        
        // Set neutral gradient environment for clean, professional rendering
        await MainActor.run {
            // Use a subtle gradient background instead of flat white
            // This provides better depth perception without introducing distracting elements
            renderView.environment.background = .color(UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0))
            
            // Add our anchors directly to the scene
            renderView.scene.addAnchor(anchor)
            renderView.scene.addAnchor(lightAnchor)
            
            // Force immediate render
            renderView.layoutIfNeeded()
        }
        
        // Capture the rendered image using async continuation
        let image = await withCheckedContinuation { continuation in
            renderView.snapshot(saveToHDR: false) { capturedImage in
                continuation.resume(returning: capturedImage)
            }
        }
        
        // Immediately clean up the view
        await MainActor.run {
            renderView.scene.anchors.removeAll()
            renderView.removeFromSuperview()
        }
        
        return image
    }
    #endif
}
