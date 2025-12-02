//
//  OffscreenIndicatorView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI

struct OffscreenIndicatorView: View {
    @Binding var isVisible: Bool
    @Binding var position: CGPoint
    @Binding var angle: Angle

    var body: some View {
        if isVisible {
            Image(systemName: "triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(.red)
                .rotationEffect(angle)
                .position(position)
        }
    }
}
