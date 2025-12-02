//
//  CharacterModelController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

import SwiftUI
import RealityKit
#if os(iOS)
import ARKit
#endif
import Combine
import Metal

/// Centralized RealityKit-based AR scene controller
/// Platform-specific functionality is in extensions:
/// - CharacterModelController+iOS.swift
/// - CharacterModelController+visionOS.swift
/// - CharacterModelController+Shaders.swift
@MainActor
public class CharacterModelController: ObservableObject {
    public static let shared = CharacterModelController()
    
    // MARK: - Published Properties
    public internal(set) var hasPlacedModel: Bool = false
    
    // MARK: - Model State
    #if os(iOS)
    internal var arView: ARView?
    internal var lastPlaneTransform: simd_float4x4?
    internal var lastPlaneExtent: SIMD2<Float>?
    internal var lastPlaneClassification: ARPlaneAnchor.Classification?
    internal var knownPlanes: [UUID: ARPlaneAnchor] = [:]
    internal var fallbackWorkItem: DispatchWorkItem?
    #endif
    
    public var modelEntity: ModelEntity?
    internal var modelAnchor: AnchorEntity?
    
    // MARK: - Preload Cache
    private var preloadedEntity: ModelEntity?
    private var preloadedModelName: String?
    
    // MARK: - Shader Resources
    internal var metalDevice: MTLDevice?
    internal var metalLibrary: MTLLibrary?
    #if os(iOS)
    internal var celSurfaceShader: CustomMaterial.SurfaceShader?
    internal var celGeometryModifier: CustomMaterial.GeometryModifier?
    internal var loadedShaders: [String: CustomMaterial.SurfaceShader] = [:]
    internal var geometryModifierLoaded = false
    #endif
    internal var originalMaterials: [ModelEntity: [RealityKit.Material]] = [:]

    
    // MARK: - State Flags
    internal var isLoadingModel: Bool = false

    // MARK: - Blendshape Cache
    /// Stores requested blendshape weights keyed by blendshape name. These are applied when
    /// a model is present and RealityKit provides morph-target APIs for the model type.
    /// For now we keep a safe cache so callers can set blendshape values even when the
    /// runtime application of morph targets is not yet available in this codebase.
    internal var blendshapeWeights: [String: Float] = [:]
    
    // MARK: - Combine
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: Notification.Name("virtualportal.arConfigurationChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartARSession()
            }
        }
        #endif
    }
    
    // MARK: - Shared Methods
    
    /// Clean up resources to prevent memory leaks
    internal func cleanup() {
        cancellables.removeAll()
        metalDevice = nil
        metalLibrary = nil
        #if os(iOS)
        celSurfaceShader = nil
        celGeometryModifier = nil
        #endif
        originalMaterials = [:]
        isLoadingModel = false
    }
    
    /// Helper to load a ModelEntity
    internal func loadModelEntity(contentsOf url: URL) async throws -> ModelEntity {
        // Minimal checks - just load it
        guard !url.path.isEmpty else {
            throw NSError(domain: "CharacterModelController", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Invalid URL path"])
        }
        
        // Load directly - ModelEntity will throw if file doesn't exist
        return try await ModelEntity(contentsOf: url)
    }
    
    /// Preload a model in the background to speed up first placement
    public func preloadModel(modelName: String) async {
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Cannot preload empty model name")
            return
        }
        
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if already preloaded
        if preloadedModelName == trimmedName, preloadedEntity != nil {
            print("Model '\(trimmedName)' already preloaded")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        let modelURL = modelsPath.appendingPathComponent(trimmedName)
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("Cannot preload - model not found: \(trimmedName)")
            return
        }
        
        print("Preloading model: \(trimmedName)...")
        
        // Load in background with low priority to not interfere with app startup
        Task.detached(priority: .utility) {
            do {
                let startTime = CACurrentMediaTime()
                // Load directly without going through self
                let entity = try await ModelEntity(contentsOf: modelURL)
                let duration = CACurrentMediaTime() - startTime
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.preloadedEntity = entity
                    self.preloadedModelName = trimmedName
                    print("Model preloaded in \(String(format: "%.2f", duration))s: \(trimmedName)")
                }
            } catch {
                print("Failed to preload model: \(error)")
            }
        }
    }
    
    /// Get preloaded entity if available, otherwise load normally
    internal func getOrLoadModelEntity(contentsOf url: URL, modelName: String) async throws -> ModelEntity {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if we have a preloaded entity for this model
        if let preloaded = preloadedEntity, preloadedModelName == trimmedName {
            print("Using preloaded model: \(trimmedName)")
            // Clear the cache so it's not reused
            preloadedEntity = nil
            preloadedModelName = nil
            return preloaded
        }
        
        // Not preloaded, load normally
        print("Loading model from disk: \(trimmedName)")
        return try await loadModelEntity(contentsOf: url)
    }
    
    /// Reset all state and remove model from scene
    public func reset() {
        #if os(iOS)
        if let arView = arView, let anchor = modelAnchor {
            arView.scene.removeAnchor(anchor)
        }
        #elseif os(visionOS)
        modelEntity?.removeFromParent()
        #endif
        
        modelEntity = nil
        modelAnchor = nil
        hasPlacedModel = false
        
        #if os(iOS)
        arView = nil
        lastPlaneTransform = nil
        lastPlaneExtent = nil
        lastPlaneClassification = nil
        knownPlanes.removeAll()
        isLoadingModel = false
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        celSurfaceShader = nil
        celGeometryModifier = nil
        #endif
        
        originalMaterials = [:]
        metalLibrary = nil
        metalDevice = nil
        
        print("CharacterModelController reset")
    }
    
    // MARK: - Blendshape Methods
    
    /// Set a blendshape (morph target) value on the current model.
    ///
    /// This implementation safely caches the requested weight and attempts a best-effort
    /// application when a model is present. RealityKit morph-target APIs vary across
    /// versions; if your models expose morph targets directly we can wire a concrete
    /// application path (please provide a sample model or morph target naming).
    public func setBlendShape(name: String, value: Float) {
        let clamped = max(0.0, min(1.0, value))
        blendshapeWeights[name] = clamped

        // Try best-effort application if modelEntity exists. If we cannot find a supported
        // morph API in this runtime, we keep the cache so weights can be applied later.
        if let entity = modelEntity {
            applyCachedBlendShapes(to: entity)
        }
    }
    
    /// Reset all cached blendshapes and attempt to clear any applied weights on the model.
    public func resetBlendShapes() {
        blendshapeWeights.removeAll()

        if let entity = modelEntity {
            // Best-effort: attempt to clear weights if supported by the runtime.
            applyCachedBlendShapes(to: entity)
        }

        print("Cleared cached blendshapes")
    }
    
    /// Get blendshape names currently cached (or empty if none).
    public func getBlendShapeNames() -> [String] {
        return Array(blendshapeWeights.keys)
    }

    // MARK: - Blendshape Application (best-effort)

    /// Attempt to apply cached blendshape weights to the given `ModelEntity`.
    ///
    /// This function includes a placeholder where a concrete RealityKit morph-target
    /// application should be implemented once the target API / model format is known.
    internal func applyCachedBlendShapes(to entity: ModelEntity) {
        // If there are no cached weights there's nothing to do
        guard !blendshapeWeights.isEmpty else { return }

        // NOTE: The concrete API to set morph target weights depends on RealityKit
        // and the way the USDZ/GLTF model exposes morph targets. Example approaches
        // (platform / version dependent):
        // - `modelEntity.model?.morphTargets` + `modelEntity.model?.morphTargetWeights` (older APIs)
        // - A `MorphComponent` or `SkinnedMeshComponent` type that exposes targets/weights
        // - A vendor-specific extension or animation channel
        //
        // Right now we don't call any unknown APIs to avoid compile-time errors.
        // Instead we log what would be applied and keep the cache for a follow-up
        // implementation. Provide a sample model or the exact morph target property
        // names and I will add direct application code here.

        // Intentionally quiet: avoid log spam while animating lips.
    }
}
