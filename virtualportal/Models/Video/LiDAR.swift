//
//  LiDAR.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/30/25.
//
#if os(iOS)
import AVFoundation

class LiDAR {
    public func getDepthMap() -> CVPixelBuffer? {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            return nil
        }
        // Find a match that outputs video data in the format the app's custom Metal views require.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == 420 &&
            format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            return nil
        }


        // Find a match that outputs depth data in the format the app's custom Metal views require.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            return nil
        }


        // Begin the device configuration.
        do {
            try device.lockForConfiguration()
        } catch {
            return nil
        }


        // Configure the device and depth formats.
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat


        // Finish the device configuration.
        device.unlockForConfiguration()
        
        // TODO: Actually capture and return the depth map
        return nil
    }
}
#endif