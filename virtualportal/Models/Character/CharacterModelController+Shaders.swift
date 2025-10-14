//
//  CharacterModelController+Shaders.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import SwiftUI
import RealityKit
import Metal

/// Shader management extension for CharacterModelController
extension CharacterModelController {
    
    // MARK: - Shader Initialization
    
    internal func initializeShaders() {
        guard metalDevice == nil else { return }

    print("Initializing Metal shaders...")

        metalDevice = MTLCreateSystemDefaultDevice()
        guard let device = metalDevice else {
            print("Failed to create Metal device")
            return
        }

        print("Metal device created: \(device.name)")

        // Try to load the default library from the main bundle
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.main) else {
            print("Metal library not available in bundle; custom shaders disabled")
            return
        }
        
        metalLibrary = library
    print("Metal library loaded")

        #if os(iOS)
        // Attempt to load surface shader - only available on iOS (not visionOS yet)
        celSurfaceShader = CustomMaterial.SurfaceShader(named: "cel_surface", in: library)
        celGeometryModifier = CustomMaterial.GeometryModifier(named: "cel_geometry_modifier", in: library)

        if celSurfaceShader != nil {
            print("Custom cel shader 'cel_surface' loaded successfully")
        } else {
            print("Custom shader 'cel_surface' not found in library; cel shading disabled")
            print("   Available functions in library:")
            for name in library.functionNames {
                print("   - \(name)")
            }
        }
        #else
        print("ℹ️ Custom shaders not yet supported on this platform")
        #endif
    }
    
    // MARK: - Shader Application
    
    internal func applyShaderToEntity(_ entity: ModelEntity) {
        #if os(iOS)
        // Apply shader only if we have a surface shader available
        guard let surfaceShader = celSurfaceShader else {
            print("⚠️ Surface shader not initialized - cel rendering disabled")
            return
        }

        let entityName = entity.name.isEmpty ? "<unnamed>" : entity.name
    print("Applying cel shader to entity: \(entityName)")

        // Collect all entities first to batch process
        var entitiesToProcess: [ModelEntity] = []
        var queue: [Entity] = [entity]
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let modelEntity = current as? ModelEntity, modelEntity.model?.materials != nil {
                entitiesToProcess.append(modelEntity)
            }
            queue.append(contentsOf: current.children)
        }
        
        print("   Found \(entitiesToProcess.count) entities with materials to process")
        
        // Process entities in smaller batches to allow UI updates
        let batchSize = 5
        for batchStart in stride(from: 0, to: entitiesToProcess.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entitiesToProcess.count)
            let batch = entitiesToProcess[batchStart..<batchEnd]
            
            for modelEntity in batch {
                guard let materials = modelEntity.model?.materials else { continue }
                
                var shadedMaterials: [any RealityKit.Material] = []
                shadedMaterials.reserveCapacity(materials.count)

                for material in materials {
                    do {
                        // Try to create a CustomMaterial from existing material
                        if let geomMod = celGeometryModifier {
                            let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader, geometryModifier: geomMod)
                            shadedMaterials.append(customMat)
                        } else {
                            let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader)
                            shadedMaterials.append(customMat)
                        }
                    } catch {
                        // Fail silently and use original material
                        shadedMaterials.append(material)
                    }
                }

                modelEntity.model?.materials = shadedMaterials
            }
        }
        
        print("   Cel shader applied to \(entitiesToProcess.count) entities")
        #else
        print("Custom shaders not supported on this platform")
        #endif
    }
    
    /// Async version that yields between batches to keep UI responsive
    @MainActor
    internal func applyShaderToEntityAsync(_ entity: ModelEntity) async {
        #if os(iOS)
        guard let surfaceShader = celSurfaceShader else {
            print("⚠️ Surface shader not initialized - cel rendering disabled")
            return
        }

        let entityName = entity.name.isEmpty ? "<unnamed>" : entity.name
    print("Applying cel shader async to entity: \(entityName)")

        // Collect all entities
        var entitiesToProcess: [ModelEntity] = []
        var queue: [Entity] = [entity]
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let modelEntity = current as? ModelEntity, modelEntity.model?.materials != nil {
                entitiesToProcess.append(modelEntity)
            }
            queue.append(contentsOf: current.children)
        }
        
        print("   Found \(entitiesToProcess.count) entities with materials to process")
        
        // Process in small batches with yields to keep UI responsive
        let batchSize = 3
        var processedCount = 0
        
        for batchStart in stride(from: 0, to: entitiesToProcess.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entitiesToProcess.count)
            let batch = entitiesToProcess[batchStart..<batchEnd]
            
            for modelEntity in batch {
                guard let materials = modelEntity.model?.materials else { continue }
                
                var shadedMaterials: [any RealityKit.Material] = []
                shadedMaterials.reserveCapacity(materials.count)

                for material in materials {
                    do {
                        if let geomMod = celGeometryModifier {
                            let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader, geometryModifier: geomMod)
                            shadedMaterials.append(customMat)
                        } else {
                            let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader)
                            shadedMaterials.append(customMat)
                        }
                    } catch {
                        shadedMaterials.append(material)
                    }
                }

                modelEntity.model?.materials = shadedMaterials
                processedCount += 1
            }
            
            // Yield after each batch to allow UI updates
            await Task.yield()
        }
        
        print("   Cel shader applied async to \(processedCount) entities")
        #else
        print("Custom shaders not supported on this platform")
        #endif
    }
    
    internal func restoreOriginalMaterials(_ entity: ModelEntity) {
        guard let originalMaterials = originalMaterials else {
            print("No original materials stored")
            return
        }
        
        entity.model?.materials = originalMaterials
        
        // Recursively restore for children
        for child in entity.children {
            if let childModel = child as? ModelEntity {
                restoreOriginalMaterials(childModel)
            }
        }
    }
}
