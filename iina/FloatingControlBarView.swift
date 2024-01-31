//
//  FloatingControlBarView.swift
//  iina
//
//  Created by lhc on 16/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

// The control bar when position=="floating"
class FloatingControlBarView: NSVisualEffectView {
  private static let barHeight: CGFloat = 67
  private static let minBarWidth: CGFloat = 200
  private static let preferredBarWidth: CGFloat = 440
  private static let margin: CGFloat = CGFloat(max(0, Preference.integer(for: .floatingControlBarMargin)))

  @IBOutlet weak var xConstraint: NSLayoutConstraint!  // this is X CENTER of OSC
  @IBOutlet weak var yConstraint: NSLayoutConstraint!  // Bottom of OSC

  weak var leadingMarginConstraint: NSLayoutConstraint!
  weak var trailingMarginConstraint: NSLayoutConstraint!
  weak var bottomMarginConstraint: NSLayoutConstraint!

  var mousePosRelatedToView: CGPoint?

  var isDragging: Bool = false

  private var isAlignFeedbackSent = false

  private var playerWindowController: PlayerWindowController? {
    return window?.windowController as? PlayerWindowController
  }

  private var viewportView: NSView? {
    return playerWindowController?.viewportView
  }

  override func awakeFromNib() {
    self.roundCorners(withRadius: 6)
    self.translatesAutoresizingMaskIntoConstraints = false
  }

  func addMarginConstraints() {
    guard let wc = playerWindowController, let contentView = wc.window?.contentView else { return }
    if leadingMarginConstraint == nil || !leadingMarginConstraint.isActive {
      leadingMarginConstraint = self.leadingAnchor.constraint(greaterThanOrEqualTo: wc.leadingSidebarView.trailingAnchor, constant: FloatingControlBarView.margin)
      leadingMarginConstraint.isActive = true
    }
    if trailingMarginConstraint == nil || !trailingMarginConstraint.isActive {
      trailingMarginConstraint = wc.trailingSidebarView.leadingAnchor.constraint(greaterThanOrEqualTo: self.trailingAnchor, constant: FloatingControlBarView.margin)
      trailingMarginConstraint.isActive = true
    }
    if bottomMarginConstraint == nil || !bottomMarginConstraint.isActive {
      bottomMarginConstraint = self.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: FloatingControlBarView.margin)
      bottomMarginConstraint.isActive = true
    }
  }

  func removeMarginConstraints() {
    if let leadingMarginConstraint {
      leadingMarginConstraint.isActive = false
    }
    if let trailingMarginConstraint {
      trailingMarginConstraint.isActive = false
    }
    if let bottomMarginConstraint {
      bottomMarginConstraint.isActive = false
    }
  }

  // MARK: - Positioning

  func moveTo(centerRatioH ratioH: CGFloat, originRatioV ratioV: CGFloat, layout: PlayerWindowController.LayoutState, viewportSize: CGSize) {
    guard ratioH >= 0 && ratioH <= 1 else {
      if let playerWindowController {
        playerWindowController.log.error("FloatingOSC: cannot update position; centerRatioH is invalid: \(ratioH)")
      }
      return
    }
    guard ratioV >= 0 && ratioV <= 1 else {
      if let playerWindowController {
        playerWindowController.log.error("FloatingOSC: cannot update position; originRatioV is invalid: \(ratioV)")
      }
      return
    }

    let geometry = FloatingControllerGeometry(windowLayout: layout, viewportSize: viewportSize)
    let availableWidth = geometry.availableWidth
    let centerX = geometry.minCenterX + ((availableWidth - geometry.barWidth) * ratioH)
    let originY = geometry.minOriginY + (ratioV * (geometry.maxOriginY - geometry.minOriginY))
    let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: centerX, originY: originY)
//    Logger.log("Setting xConstraint to: \(xConst), from \(geometry.minCenterX) + ((\(availableWidth) - \(geometry.barWidth)) * \(ratioH))", level: .verbose)
    xConstraint.animateToConstant(xConst)
    yConstraint.animateToConstant(yConst)
  }

  /// Converts the relative offsets of `xConst` and `yConst` into ratios into available space in the range [0...1]
  private func updateRatios(xConst: CGFloat, yConst: CGFloat, _ geometry: FloatingControllerGeometry) {
    guard let playerWindowController else { return }
    let minCenterX = geometry.minCenterX

    // save final position
    let ratioH = (xConst - minCenterX) / (geometry.availableWidth - geometry.barWidth)
    let minOriginY = geometry.minOriginY
    let ratioV = (yConst - minOriginY) / (geometry.maxOriginY - minOriginY)
    //    Logger.log("Drag: Setting ratioH to: (\(xConst) - \(minCenterX)) / (\(geometry.availableWidth) - \(geometry.barWidth)) = \(ratioH)", level: .verbose)

    // Save in window for use when resizing, etc.
    playerWindowController.floatingOSCCenterRatioH = ratioH
    playerWindowController.floatingOSCOriginRatioV = ratioV
    // Save to prefs as future default
    Preference.set(ratioH, for: .controlBarPositionHorizontal)
    Preference.set(ratioV, for: .controlBarPositionVertical)
  }

  // MARK: - Mouse Events

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  override func mouseDown(with event: NSEvent) {
    guard let viewportView = playerWindowController?.viewportView else { return }

    mousePosRelatedToView = self.convert(event.locationInWindow, from: nil)
    let originInViewport = viewportView.convert(frame.origin, from: nil)
    isAlignFeedbackSent = abs(originInViewport.x - (viewportView.frame.width - frame.width) / 2) <= Constants.Distance.floatingControllerSnapToCenterThreshold
    isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mouseLocInView = mousePosRelatedToView,
          let playerWindowController,
          let viewportView = playerWindowController.viewportView else {
      return
    }

    guard isDragging else { return }

    let currentLocInViewport = viewportView.convert(event.locationInWindow, from: nil)
    let geometry = FloatingControllerGeometry(windowLayout: playerWindowController.currentLayout, viewportSize: viewportView.frame.size)

    var newCenterX = currentLocInViewport.x - mouseLocInView.x + geometry.halfBarWidth
    let newOriginY = currentLocInViewport.y - mouseLocInView.y
    // stick to center
    if Preference.bool(for: .controlBarStickToCenter) {
      let xPosWhenCenter = geometry.centerX
      if abs(newCenterX - xPosWhenCenter) <= Constants.Distance.floatingControllerSnapToCenterThreshold {
        newCenterX = xPosWhenCenter
        if !isAlignFeedbackSent {
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
          isAlignFeedbackSent = true
        }
      } else {
        isAlignFeedbackSent = false
      }
    }

    let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: newCenterX, originY: newOriginY)
    xConstraint.constant = xConst
    yConstraint.constant = yConst
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false
    guard let playerWindowController, let viewportView = playerWindowController.viewportView else { return }

    let geometry = FloatingControllerGeometry(windowLayout: playerWindowController.currentLayout, viewportSize: viewportView.frame.size)

    if event.clickCount == 2 {
      let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: geometry.centerX, originY: frame.origin.y)

      // apply position
      xConstraint.animateToConstant(xConst)
      yConstraint.animateToConstant(yConst)

      updateRatios(xConst: xConst, yConst: yConst, geometry)
    } else {
      updateRatios(xConst: xConstraint.constant, yConst: yConstraint.constant, geometry)
    }
  }

  // MARK: - Coordinates in Viewport

  struct FloatingControllerGeometry {
    let windowLayout: PlayerWindowController.LayoutState
    let viewportSize: CGSize

    // "available" == space to move OSC within
    var availableWidthMinX: CGFloat {
      return windowLayout.insideLeadingBarWidth + FloatingControlBarView.margin
    }

    var availableWidthMaxX: CGFloat {
      let viewportMaxX = viewportSize.width
      let trailingUsedSpace = windowLayout.insideTrailingBarWidth + FloatingControlBarView.margin
      return max(viewportMaxX - trailingUsedSpace, FloatingControlBarView.margin + FloatingControlBarView.minBarWidth)
    }

    var availableWidth: CGFloat {
      return availableWidthMaxX - availableWidthMinX
    }

    var barWidth: CGFloat {
      if availableWidth < FloatingControlBarView.preferredBarWidth {
        return FloatingControlBarView.minBarWidth
      }
      return FloatingControlBarView.preferredBarWidth
    }

    var halfBarWidth: CGFloat {
      return barWidth / 2
    }

    var minCenterX: CGFloat {
      return availableWidthMinX + halfBarWidth
    }

    // Centered
    var maxCenterX: CGFloat {
      return availableWidthMaxX - halfBarWidth
    }

    var minOriginY: CGFloat {
      // There is no bottom bar is OSC is floating
      return FloatingControlBarView.margin
    }

    var maxOriginY: CGFloat {
      let maxYWithoutTopBar = viewportSize.height - FloatingControlBarView.barHeight - FloatingControlBarView.margin
      let topBarHeight = windowLayout.insideTopBarHeight
      let value = maxYWithoutTopBar - topBarHeight
      // ensure sanity
      return max(value, FloatingControlBarView.barHeight + FloatingControlBarView.margin)
    }

    var centerX: CGFloat {
      let minX = minCenterX
      let maxX = maxCenterX
      let availableWidth = maxX - minX
      return minX + (availableWidth * 0.5)
    }

    func calculateConstraintConstants(centerX: CGFloat, originY: CGFloat) -> (CGFloat, CGFloat) {
      let minOriginY = minOriginY
      let minCenterX = minCenterX
      let maxCenterX = maxCenterX
      let maxOriginY = maxOriginY
      // bound to viewport frame
      let constraintRect = NSRect(x: minCenterX, y: minOriginY, width: maxCenterX - minCenterX, height: maxOriginY - minOriginY)
      let newOrigin = CGPoint(x: centerX, y: originY).constrained(to: constraintRect)
      return (newOrigin.x, newOrigin.y)
    }

  }

}