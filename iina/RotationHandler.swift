//
//  VideoRotationHandler.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-26.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class VideoRotationHandler {

  // Current rotation of videoView
  private var cgCurrentRotationDegrees: CGFloat = 0

  unowned var mainWindowController: MainWindowController! = nil
  private var player: PlayerCore { mainWindowController.player }
  private var videoView: VideoView { mainWindowController.videoView }

  @objc func handleRotationGesture(recognizer: NSRotationGestureRecognizer) {
    guard Preference.enum(for: .rotateAction) == Preference.RotateAction.rotateVideoByQuarters else { return }

    switch recognizer.state {
    case .began, .changed:
      let cgNewRotationDegrees = recognizer.rotationInDegrees
      UIAnimation.disableAnimation {
        rotateVideoView(toDegrees: cgNewRotationDegrees)
      }
      break
    case .failed, .cancelled:
      UIAnimation.disableAnimation {
        rotateVideoView(toDegrees: 0)
      }
      break
    case .ended:
      // mpv and CoreGraphics rotate in opposite directions
      let mpvNormalizedRotationDegrees = normalizeRotation(Int(-recognizer.rotationInDegrees))
      let mpvClosestQuarterRotation = findClosestQuarterRotation(mpvNormalizedRotationDegrees)
      guard mpvClosestQuarterRotation != 0 else {
        // Zero degree rotation: no change.
        // Don't "unwind" if more than 360° rotated; just take shortest partial circle back to origin
        cgCurrentRotationDegrees -= completeCircleDegrees(of: cgCurrentRotationDegrees)
        Logger.log("Rotation gesture of \(recognizer.rotationInDegrees)° will not change video rotation. Snapping back from: \(cgCurrentRotationDegrees)°")
        rotateVideoView(toDegrees: 0)
        return
      }

      // Snap to one of the 4 quarter circle rotations
      let mpvNewRotation = (player.info.userRotation + mpvClosestQuarterRotation) %% 360
      Logger.log("User's gesture of \(recognizer.rotationInDegrees)° is equivalent to mpv \(mpvNormalizedRotationDegrees)°, which is closest to \(mpvClosestQuarterRotation)°. Adding it to current mpv rotation (\(player.info.userRotation)°) → new rotation will be \(mpvNewRotation)°")
      // Need to convert snap-to location back to CG, to feed to animation
      let cgSnapToDegrees = findNearestCGQuarterRotation(forCGRotation: recognizer.rotationInDegrees,
                                                         equalToMpvRotation: mpvClosestQuarterRotation)
      rotateVideoView(toDegrees: cgSnapToDegrees)
      player.setVideoRotate(mpvNewRotation)

    default:
      return
    }
  }

  // Returns the total degrees in the given rotation which are due to complete 360° rotations
  private func completeCircleDegrees(of rotationDegrees: CGFloat) -> CGFloat{
    CGFloat(Int(rotationDegrees / 360) * 360)
  }

  // Reduces the given rotation to one which is a positive number between 0 and 360 degrees and has the same resulting orientation.
  private func normalizeRotation(_ rotationDegrees: Int) -> Int {
    // Take out all full rotations so we end up with number between -360 and 360
    let simplifiedRotation = rotationDegrees %% 360
    // Remove direction and return a number from 0..<360
    return simplifiedRotation < 0 ? simplifiedRotation + 360 : simplifiedRotation
  }

  // Find which 90° rotation the given rotation is closest to (within 45° of it).
  private func findClosestQuarterRotation(_ mpvNormalizedRotationDegrees: Int) -> Int {
    assert(mpvNormalizedRotationDegrees >= 0 && mpvNormalizedRotationDegrees < 360)
    for quarterCircleRotation in AppData.rotations {
      if mpvNormalizedRotationDegrees < quarterCircleRotation + 45 {
        return quarterCircleRotation
      }
    }
    return AppData.rotations[0]
  }

  private func findNearestCGQuarterRotation(forCGRotation cgRotationInDegrees: CGFloat, equalToMpvRotation mpvQuarterRotation: Int) -> CGFloat {
    let cgCompleteCirclesTotalDegrees = completeCircleDegrees(of: cgRotationInDegrees)
    let cgClosestQuarterRotation = CGFloat(normalizeRotation(-mpvQuarterRotation))
    let cgLessThanWholeRotation = cgRotationInDegrees - cgCompleteCirclesTotalDegrees
    let cgSnapToDegrees: CGFloat
    if cgLessThanWholeRotation > 0 {
      // positive direction:
      cgSnapToDegrees = cgCompleteCirclesTotalDegrees + cgClosestQuarterRotation
    } else {
      // negative direction:
      cgSnapToDegrees = cgCompleteCirclesTotalDegrees + (cgClosestQuarterRotation - 360)
    }
    Logger.log("mpvQuarterRotation: \(mpvQuarterRotation) cgCompleteCirclesTotalDegrees: \(cgCompleteCirclesTotalDegrees)° cgLessThanWholeRotation: \(cgLessThanWholeRotation); cgClosestQuarterRotation: \(cgClosestQuarterRotation)° -> cgSnapToDegrees: \(cgSnapToDegrees)°")
    return cgSnapToDegrees
  }

  // Side effect: sets `cgCurrentRotationDegrees` to `toDegrees` before returning
  func rotateVideoView(toDegrees: CGFloat) {
    let fromDegrees = cgCurrentRotationDegrees
    let toRadians = degToRad(toDegrees)

    // Animation is enabled by default for this view.
    // We only want to animate some rotations and not others, and never want to animate
    // position change. So put these in an explicitly disabled transaction block:
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Rotate about center point. Also need to change position because.
    let centerPoint = CGPointMake(NSMidX(videoView.frame), NSMidY(videoView.frame))
    videoView.layer?.position = centerPoint
    videoView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    CATransaction.commit()

    if UIAnimation.isAnimationEnabled {
      Logger.log("Animating rotation from \(fromDegrees)° to \(toDegrees)°")

      CATransaction.begin()
      // This will show an animation but doesn't change its permanent state.
      // Still need the rotation call down below to do that.
      let rotateAnimation = CABasicAnimation(keyPath: "transform")
      rotateAnimation.valueFunction = CAValueFunction(name: .rotateZ)
      rotateAnimation.fromValue = degToRad(fromDegrees)
      rotateAnimation.toValue = toRadians
      rotateAnimation.duration = 0.2
      videoView.layer?.add(rotateAnimation, forKey: "transform")
      CATransaction.commit()
    }

    // This block updates the view's permanent position, but won't animate.
    // Need to call this even if running the animation above, or else layer will revert to its prev appearance after
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoView.layer?.transform = CATransform3DMakeRotation(toRadians, 0, 0, 1)
    CATransaction.commit()

    cgCurrentRotationDegrees = toDegrees
  }

  private func degToRad(_ degrees: CGFloat) -> CGFloat {
    return degrees * CGFloat.pi / 180
  }

}