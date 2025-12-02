//
//  HandInputHandler.swift
//  virtualportal
//
//  Created by Yukari Kaname on 8/20/25.
//

#if os(visionOS)
import Foundation
import Vision
import Combine
import CoreGraphics

/// Recognizable hand shapes returned by the handler.
public enum HandShape: String {
	case open
	case fist
	case point
	case pinch
	case peace
	case thumbsUp
	case lShape
	case unknown
}

/// A small, self-contained visionOS hand input handler that converts
/// `VNHumanHandPoseObservation` instances into a best-guess `HandShape`.
///
/// This class focuses on geometric heuristics (finger curl, tip distances)
/// so it can be used wherever VN observations are available (AR frames,
/// camera feeds, etc.). It purposely does not manage camera/session lifecycles.
public final class HandInputHandler {
	/// Published current detected shape (debounced).
	@Published public private(set) var currentShape: HandShape = .unknown

	/// Optional callback when a new shape is detected.
	public var onShapeDetected: ((HandShape) -> Void)?

	private var cancellables = Set<AnyCancellable>()

	public init() {}

	/// Process a single hand-pose observation and update the detected shape.
	/// - Parameter observation: A `VNHumanHandPoseObservation` containing joint locations.
	public func process(observation: VNHumanHandPoseObservation) {
		let shape = detectShape(from: observation)
		// Only publish when changed to reduce noise
		if shape != currentShape {
			currentShape = shape
			onShapeDetected?(shape)
		}
	}

	// MARK: - Detection logic

	private func detectShape(from obs: VNHumanHandPoseObservation) -> HandShape {
		// try to obtain key joint points; if missing, return unknown
		guard let thumbTip = try? obs.recognizedPoint(.thumbTip), thumbTip.confidence > 0.2,
			  let thumbIP = try? obs.recognizedPoint(.thumbIP),
			  let indexTip = try? obs.recognizedPoint(.indexTip), indexTip.confidence > 0.2
//			  let indexPIP = try? obs.recognizedPoint(.indexPIP),
//			  let middleTip = try? obs.recognizedPoint(.middleTip),
//			  let ringTip = try? obs.recognizedPoint(.ringTip),
//			  let littleTip = try? obs.recognizedPoint(.littleTip)
		else {
			return .unknown
		}

		// normalize to 2D points
		let tTip = CGPoint(x: CGFloat(thumbTip.location.x), y: CGFloat(thumbTip.location.y))
		let tIP = CGPoint(x: CGFloat(thumbIP.location.x), y: CGFloat(thumbIP.location.y))
		let iTip = CGPoint(x: CGFloat(indexTip.location.x), y: CGFloat(indexTip.location.y))
//		let iPIP = CGPoint(x: CGFloat(indexPIP.location.x), y: CGFloat(indexPIP.location.y))
//		let mTip = CGPoint(x: CGFloat(middleTip.location.x), y: CGFloat(middleTip.location.y))
//		let rTip = CGPoint(x: CGFloat(ringTip.location.x), y: CGFloat(ringTip.location.y))
//		let lTip = CGPoint(x: CGFloat(littleTip.location.x), y: CGFloat(littleTip.location.y))

		// Compute simple curl estimates for each finger by measuring angle at the PIP joint
		let indexCurl = fingerCurl(observation: obs, mcp: .indexMCP, pip: .indexPIP, tip: .indexTip)
		let middleCurl = fingerCurl(observation: obs, mcp: .middleMCP, pip: .middlePIP, tip: .middleTip)
		let ringCurl = fingerCurl(observation: obs, mcp: .ringMCP, pip: .ringPIP, tip: .ringTip)
		let littleCurl = fingerCurl(observation: obs, mcp: .littleMCP, pip: .littlePIP, tip: .littleTip)
		let thumbCurl = thumbCurlAngle(ip: tIP, tip: tTip, carp: try? obs.recognizedPoint(.thumbCMC))

		// Distances for pinch detection
		let thumbIndexDist = distance(tTip, iTip)

		// heuristic thresholds (tuned conservatively)
		let curledThreshold: CGFloat = .pi / 2.0 // ~90 deg
//		let extendedThreshold: CGFloat = 2.3 // rad ~132deg (cos-based) — larger means more straight
		let pinchDistanceThreshold: CGFloat = 0.06 // normalized image units (may need tuning)

		// Fist: all fingers curled
		if indexCurl > curledThreshold && middleCurl > curledThreshold && ringCurl > curledThreshold && littleCurl > curledThreshold && thumbCurl > 0.9 {
			return .fist
		}

		// Pinch: thumb near index tip and both relatively curled
		if thumbIndexDist < pinchDistanceThreshold {
			return .pinch
		}

		// Point: index extended, others curled
		if indexCurl < (curledThreshold * 0.7) && middleCurl > curledThreshold && ringCurl > curledThreshold && littleCurl > curledThreshold {
			return .point
		}

		// Peace: index and middle extended, others curled
		if indexCurl < (curledThreshold * 0.8) && middleCurl < (curledThreshold * 0.8) && ringCurl > curledThreshold && littleCurl > curledThreshold {
			return .peace
		}

		// Thumbs-up: thumb extended and other fingers curled
		if thumbCurl < (curledThreshold * 0.8) && indexCurl > curledThreshold && middleCurl > curledThreshold && ringCurl > curledThreshold && littleCurl > curledThreshold {
			return .thumbsUp
		}

		// L-shape: thumb and index extended and roughly orthogonal
		if indexCurl < (curledThreshold * 0.9) && thumbCurl < (curledThreshold * 0.9) {
			// vector thumb -> tip and index pip->tip approximate directions
			if let thumbCMC = try? obs.recognizedPoint(.thumbCMC), thumbCMC.confidence > 0.1,
			   let indexMCP = try? obs.recognizedPoint(.indexMCP), indexMCP.confidence > 0.1 {
				let vThumb = CGPoint(x: CGFloat(tTip.x - thumbCMC.location.x), y: CGFloat(tTip.y - thumbCMC.location.y))
				let vIndex = CGPoint(x: CGFloat(iTip.x - indexMCP.location.x), y: CGFloat(iTip.y - indexMCP.location.y))
				let ang = angleBetween(vThumb, vIndex)
				// close to 90 degrees
				if abs(ang - (.pi/2)) < .pi/6 {
					return .lShape
				}
			}
		}

		// Open: most fingers extended
		let extendedCount = [indexCurl, middleCurl, ringCurl, littleCurl].filter { $0 < (curledThreshold * 0.9) }.count
		if extendedCount >= 3 && thumbCurl < 1.4 {
			return .open
		}

		return .unknown
	}

	// MARK: - Geometric helpers

	private func fingerCurl(observation obs: VNHumanHandPoseObservation, mcp: VNHumanHandPoseObservation.JointName, pip: VNHumanHandPoseObservation.JointName, tip: VNHumanHandPoseObservation.JointName) -> CGFloat {
		guard let mcpP = try? obs.recognizedPoint(mcp), mcpP.confidence > 0.1,
			  let pipP = try? obs.recognizedPoint(pip), pipP.confidence > 0.1,
			  let tipP = try? obs.recognizedPoint(tip), tipP.confidence > 0.1
		else { return 0 }

		let a = CGPoint(x: CGFloat(mcpP.location.x), y: CGFloat(mcpP.location.y))
		let b = CGPoint(x: CGFloat(pipP.location.x), y: CGFloat(pipP.location.y))
		let c = CGPoint(x: CGFloat(tipP.location.x), y: CGFloat(tipP.location.y))

		return angleBetween(CGPoint(x: b.x - a.x, y: b.y - a.y), CGPoint(x: c.x - b.x, y: c.y - b.y))
	}

	private func thumbCurlAngle(ip: CGPoint, tip: CGPoint, carp: VNRecognizedPoint?) -> CGFloat {
		guard let carp = carp, carp.confidence > 0.1 else {
			// fallback: use IP-Tip vector as measure; smaller angle -> more extended
			let v = CGPoint(x: tip.x - ip.x, y: tip.y - ip.y)
			return atan2(abs(v.x), abs(v.y))
		}
		let c = CGPoint(x: CGFloat(carp.location.x), y: CGFloat(carp.location.y))
		return angleBetween(CGPoint(x: ip.x - c.x, y: ip.y - c.y), CGPoint(x: tip.x - ip.x, y: tip.y - ip.y))
	}

	private func angleBetween(_ v1: CGPoint, _ v2: CGPoint) -> CGFloat {
		let a = v1.x * v2.x + v1.y * v2.y
		let mag1 = sqrt(v1.x * v1.x + v1.y * v1.y)
		let mag2 = sqrt(v2.x * v2.x + v2.y * v2.y)
		guard mag1 > 1e-6 && mag2 > 1e-6 else { return 0 }
		let cosv = max(-1.0, min(1.0, a / (mag1 * mag2)))
		return acos(cosv)
	}

	private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
		let dx = a.x - b.x
		let dy = a.y - b.y
		return sqrt(dx*dx + dy*dy)
	}
}

#endif
