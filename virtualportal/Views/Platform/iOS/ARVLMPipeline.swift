//
//  ARVLMPipeline.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

#if os(iOS)
import RealityKit
import ARKit
import CoreImage
import UIKit

/// Handles AR frame processing and VLM integration
@MainActor
class ARVLMPipeline {
    // VLM frame throttling - follow VLMModelManager's configured interval
    private var lastVLMFrameTime: CFTimeInterval = 0
    private var minVLMFrameInterval: CFTimeInterval {
        return CFTimeInterval(VLMModelManager.shared.processInterval)
    }

    // Reduce log spam: only emit skip logs when the reason changes
    private enum SkipReason: String { case loading, notLoaded, busy }
    private var lastSkipReason: SkipReason?
    private var lastSkipLogTime: CFTimeInterval = 0
    private let skipLogCooldown: CFTimeInterval = 5.0 // seconds between identical skip logs

    func processARFrame(_ frame: ARFrame) {
        let currentTime = CACurrentMediaTime()

        // Skip VLM processing while loading model to reduce resource contention
        guard !ModelRenderer.shared.isLoadingModel else {
            #if DEBUG
            let now = CACurrentMediaTime()
            if lastSkipReason != .loading || (now - lastSkipLogTime) >= skipLogCooldown {
                print("[VLM] Skipping frame: model loading")
                lastSkipReason = .loading
                lastSkipLogTime = now
            }
            #endif
            return
        }

        // VLM frame processing - throttled to prevent ARFrame retention
        if currentTime - lastVLMFrameTime >= minVLMFrameInterval {
            // Gate until model is loaded to avoid noisy "model not loaded" skips
            guard VLMModelManager.shared.isModelLoaded else {
                #if DEBUG
                let now = CACurrentMediaTime()
                if lastSkipReason != .notLoaded || (now - lastSkipLogTime) >= skipLogCooldown {
                    print("[VLM] Skipping frame: model not loaded yet")
                    lastSkipReason = .notLoaded
                    lastSkipLogTime = now
                }
                #endif
                return
            }
            // CRITICAL: Skip if VLM is still processing to prevent frame buildup
            guard !VLMModelManager.shared.isProcessing else {
                #if DEBUG
                let now = CACurrentMediaTime()
                if lastSkipReason != .busy || (now - lastSkipLogTime) >= skipLogCooldown {
                    print("[VLM] Skipping frame: VLM busy")
                    lastSkipReason = .busy
                    lastSkipLogTime = now
                }
                #endif
                return
            }

            // Clear skip reason when proceeding
            lastSkipReason = nil

            // CRITICAL: Check app state BEFORE any processing to prevent GPU crashes
            guard UIApplication.shared.applicationState == .active else {
                #if DEBUG
                print("[VLM] Skipping frame: app not active")
                #endif
                return
            }

            lastVLMFrameTime = currentTime

            // CRITICAL: Extract pixel data synchronously before any async work
            // This fully releases ARFrame reference before VLM processing
            let pixelData: (width: Int, height: Int, data: Data)? = autoreleasepool {
                let pixelBuffer = frame.capturedImage
                
                // Lock pixel buffer to extract raw data
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
                
                guard let baseAddress = baseAddress else { return nil }
                
                // Calculate target size (downscale)
                let scale = 480.0 / Double(max(width, height))
                let targetWidth = Int(Double(width) * scale)
                let targetHeight = Int(Double(height) * scale)
                
                // Copy pixel data immediately
                let dataSize = bytesPerRow * height
                let data = Data(bytes: baseAddress, count: dataSize)
                
                return (width: targetWidth, height: targetHeight, data: data)
            }
            
            guard let pixelData = pixelData else { return }
            
            // Now ARFrame is fully released - process asynchronously
            Task { @MainActor in
                // Recreate image from raw data
                guard let provider = CGDataProvider(data: pixelData.data as CFData),
                      let cgImage = CGImage(
                        width: pixelData.width,
                        height: pixelData.height,
                        bitsPerComponent: 8,
                        bitsPerPixel: 32,
                        bytesPerRow: pixelData.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: true,
                        intent: .defaultIntent
                      ) else { return }
                
                let ciImage = CIImage(cgImage: cgImage)
                await VLMModelManager.shared.processImage(ciImage)
            }
        }
    }
}
#endif