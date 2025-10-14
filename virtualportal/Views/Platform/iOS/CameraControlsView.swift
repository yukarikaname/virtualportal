//
//  CameraControlsView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

#if os(iOS)
import SwiftUI
import Foundation
import UIKit

extension Notification.Name {
    static let cameraCaptureRequested = Notification.Name("virtualportal.cameraCaptureRequested")
}

struct CameraControlsView: View {
    @Binding var hideControls: Bool
    var thumbnail: UIImage?
    var showFlip: Bool = true
    var onThumbnailTap: (() -> Void)?

    init(
        hideControls: Binding<Bool> = .constant(false),
        thumbnail: UIImage? = nil,
        showFlip: Bool = true,
        onThumbnailTap: (() -> Void)? = nil
    ) {
        _hideControls = hideControls
        self.thumbnail = thumbnail
        self.onThumbnailTap = onThumbnailTap
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Bottom container that pins controls to the true screen bottom
                VStack(spacing: 0) {
                    Spacer()
                    ZStack {
                        // Left thumbnail
                        HStack {
                            if let t = thumbnail {
                                Button(action: {
                                    onThumbnailTap?()
                                }) {
                                    Image(uiImage: t)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipped()
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.6), lineWidth: 1)
                                        )
                                        .cornerRadius(8)
                                        .shadow(radius: 2)
                                }
                                .padding(.leading, 18)
                                .transition(.opacity)
                                .accessibilityLabel("View captured photo")
                            } else {
                                Color.clear
                                    .frame(width: 56, height: 56)
                                    .padding(.leading, 18)
                                    .accessibilityHidden(true)
                            }
                            Spacer()
                        }

                        // Capture button - bottom center
                        HStack {
                            Spacer()
                            Button(action: {
                                NotificationCenter.default.post(name: .cameraCaptureRequested, object: nil)
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 72, height: 72)
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                        .frame(width: 88, height: 88)
                                }
                            }
                            .disabled(hideControls)
                            .opacity(hideControls ? 0 : 1)
                            Spacer()
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(!hideControls)
        }
    }
}
#endif
