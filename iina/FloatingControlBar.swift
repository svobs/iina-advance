//
//  FloatingControlBar.swift
//  iina
//
//  Created by lhc on 16/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

/// Floating OSC view with flat blended panel
final class FloatingControlBarVisualEffectView: ClickThroughVisualEffectView, DraggableObject {
  let controlBar: FloatingControlBar

  init(_ controlBar: FloatingControlBar) {
    self.controlBar = controlBar
    super.init(frame: .zero)
    blendingMode = .withinWindow
    material = .popover
    state = .active
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func mouseDown(with event: NSEvent) { controlBar.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { controlBar.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { controlBar.mouseUp(with: event) }
  func cancelDrag() { controlBar.cancelDrag() }
}

/// Floating OSC view with glass panel
@available(macOS 26.0, *)
final class FloatingControlBarGlassEffectView: ClickThroughGlassEffectView, DraggableObject {
  let controlBar: FloatingControlBar

  init(_ controlBar: FloatingControlBar, style desiredStyle: Style) {
    self.controlBar = controlBar
    super.init(desiredStyle)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func mouseDown(with event: NSEvent) { controlBar.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { controlBar.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { controlBar.mouseUp(with: event) }
  func cancelDrag() { controlBar.cancelDrag() }
}

/// Container & pseudo-controller for the "floating" OSC. Contains the view itself (`view`), its subviews, state & logic
@MainActor final class FloatingControlBar {
  static nonisolated let barHeight: CGFloat = 70
  static nonisolated let minBarWidth: CGFloat = 200
  private static nonisolated let margin: CGFloat = CGFloat(max(0, Preference.integer(for: .floatingControlBarMargin)))

  static var preferredBarWidth: CGFloat { max(FloatingControlBar.minBarWidth, CGFloat(Preference.float(for: .floatingControlBarWidth))) }

  /// The OSC root view when OSC position is `floating`.
  var view: NSView!

  var pwc: PlayerWindowController? { view.pwc }

  let topRowView = ClickThroughStackView()
  let bottomRowView = ClickThroughStackView()

  fileprivate var xConstraint: NSLayoutConstraint!  // this is X CENTER of OSC
  fileprivate var yConstraint: NSLayoutConstraint!  // Bottom of OSC

  var preferredWidthConstraint: NSLayoutConstraint!
  let leadingMarginConstraint = OptionalConstraint("OSC-Floating-LeadingMargin")
  let trailingMarginConstraint = OptionalConstraint("OSC-Floating-TrailingMargin")
  let bottomMarginConstraint = OptionalConstraint("OSC-Floating-BottomMargin")

  private var minDragDistanceMet = false
  var mousePosRelatedToView: CGPoint?
  var mouseDownLocationInWindow: CGPoint?
  private var isAlignFeedbackSent = false

  var isDragging: Bool { view.pwc?.currentDragObject == view }

  func rebuildView() {
    let subviews = [topRowView, bottomRowView]
    let view: NSView

    let colorScheme: Preference.PanelColorScheme = LayoutState.effectiveOSCFloatingColorSchemeFromPrefs
    if #available(macOS 26, *), colorScheme == .clearGlass || colorScheme == .tintedGlass {
      let style: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
      if let existingView = self.view as? FloatingControlBarGlassEffectView {
        view = existingView
        existingView.setStyle(style)
        return
      } else {
        let osdGlassView = FloatingControlBarGlassEffectView(self, style: style)
        osdGlassView.contentView!.subviews = subviews
        view = osdGlassView
        // MacOS Tahoe's style favors rounder corners. Try to fit in
        view.roundCorners(withRadius: Constants.glassCornerRadius)
      }
    } else {
      if let existingView = self.view as? FloatingControlBarVisualEffectView {
        view = existingView
        return
      } else {
        view = FloatingControlBarVisualEffectView(self)
        if #available(macOS 26, *) {
          view.roundCorners(withRadius: Constants.glassCornerRadius)
        } else {
          view.roundCorners(withRadius: 6)
        }
        view.subviews = subviews
      }
    }

    if let prevView = self.view {
      if let pwc = prevView.pwc {
        // Remove from fadeable sets (if present)
        pwc.fadeableViews.applyVisibility(.hidden, to: prevView)
      }
      prevView.removeFromSuperview()
      prevView.removeAllSubviews()
    }

    view.idString = "OSC-Floating"
    view.translatesAutoresizingMaskIntoConstraints = false

    topRowView.addConstraintsToFillSuperview(top: 10, leading: 10, trailing: 10)
    topRowView.idString = "OSC-Floating-TopRow"

    bottomRowView.addConstraintsToFillSuperview(bottom: 3, leading: 12, trailing: 12)
    bottomRowView.setHuggingPriority(.required, for: .vertical)
    bottomRowView.idString = "OSC-Floating-BottomRow"

    let rowsEqHeightCon = topRowView.heightAnchor.constraint(equalTo: bottomRowView.heightAnchor, multiplier: 1)
    rowsEqHeightCon.isActive = true

    let heightEqCon = view.heightAnchor.constraint(equalToConstant: FloatingControlBar.barHeight)
    heightEqCon.isActive = true
    preferredWidthConstraint?.isActive = false
    preferredWidthConstraint = view.widthAnchor.constraint(equalToConstant: FloatingControlBar.preferredBarWidth)
    preferredWidthConstraint.priority = .init(300)
    preferredWidthConstraint.isActive = true
    let minWidthConstraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: FloatingControlBar.minBarWidth)
    minWidthConstraint.isActive = true

    // Hide until ready for fade-in
    view.alphaValue = 0
    view.isHidden = true
    self.view = view
  }

  init() {
    for stackView in [topRowView, bottomRowView] {
      stackView.orientation = .horizontal
      stackView.alignment = .centerY
      stackView.distribution = .gravityAreas
      stackView.spacing = 0
      stackView.detachesHiddenViews = false
      stackView.translatesAutoresizingMaskIntoConstraints = false
    }

    rebuildView()
  }
  
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @MainActor
  func updatePreferredBarWidth() {
    preferredWidthConstraint.animateToConstant(FloatingControlBar.preferredBarWidth)
  }

  /// Adds margin constraints if missing
  @MainActor
  func addOrUpdateMarginConstraints(for layout: LayoutState) {
    guard let pwc, let contentView = pwc.window?.contentView else { return }
    pwc.log.verbose("Updating floating OSC constraints: leadingSidebarVisible=\(layout.leadingSidebar.isVisible.yn) traillingSidebarVisible=\(layout.leadingSidebar.isVisible.yn)")
    leadingMarginConstraint.weaken()
    trailingMarginConstraint.weaken()
    bottomMarginConstraint.weaken()

    let leadingConstraintSecondAnchor = layout.leadingSidebar.isVisible ? pwc.leadingSidebarView.trailingAnchor : contentView.leadingAnchor
    leadingMarginConstraint.createOrUpdate(to: FloatingControlBar.margin, priorityInt: 1000, requiredSecondAnchor: leadingConstraintSecondAnchor, pwc.log) { [self] c in
      view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingConstraintSecondAnchor, constant: c)
    }

    let traillingConstraintFirstAnchor = layout.trailingSidebar.isVisible ? pwc.trailingSidebarView.leadingAnchor : contentView.trailingAnchor

    trailingMarginConstraint.createOrUpdate(to: FloatingControlBar.margin, priorityInt: 1000, requiredSecondAnchor: traillingConstraintFirstAnchor, pwc.log) { [self] c in
      traillingConstraintFirstAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor, constant: c)
    }

    bottomMarginConstraint.createOrUpdate(to: FloatingControlBar.margin, priorityInt: 1000, requiredSecondAnchor: traillingConstraintFirstAnchor, pwc.log) { [self] c in
      contentView.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: c)
    }
  }

  @MainActor
  func removeFloatingControlBar() {
    view.removeFromSuperview()
    leadingMarginConstraint.remove(pwc?.log)
    trailingMarginConstraint.remove(pwc?.log)
    bottomMarginConstraint.remove(pwc?.log)
  }

  // MARK: - Positioning

  @MainActor
  fileprivate func moveToLocationRatio(parentGeo: PWinGeometry) {
    guard view.superview != nil, let pwc, let xConstraint, let yConstraint else { return }

    let ratioH = Preference.double(for: .controlBarPositionHorizontal)
    let ratioV = Preference.double(for: .controlBarPositionVertical)

    guard ratioH >= 0 && ratioH <= 1 else {
      pwc.log.error("FloatingOSC: cannot update position; centerRatioH is invalid: \(ratioH)")
      return
    }
    guard ratioV >= 0 && ratioV <= 1 else {
      pwc.log.error("FloatingOSC: cannot update position; originRatioV is invalid: \(ratioV)")
      return
    }

    let geometry = FloatingControlBarGeometry(parentGeo: parentGeo)
    let availableWidth = geometry.availableWidth
    let centerX = geometry.minCenterX + (max(0, availableWidth - geometry.barWidth) * ratioH)
    let originY = geometry.minOriginY + (ratioV * (geometry.maxOriginY - geometry.minOriginY))
    let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: centerX, originY: originY)
    pwc.log.verbose("Setting xConstraint to: \(xConst), from \(geometry.minCenterX) + ((\(availableWidth) - \(geometry.barWidth)) * \(ratioH))")
    xConstraint.animateToConstant(xConst)
    yConstraint.animateToConstant(yConst)
    updateRatios(xConst: xConst, yConst: yConst, geometry)
  }

  /// Converts the relative offsets of `xConst` and `yConst` into ratios into available space in the range [0...1]
  @MainActor
  private func updateRatios(xConst: CGFloat, yConst: CGFloat, _ geometry: FloatingControlBarGeometry) {
    let minCenterX = geometry.minCenterX

    // save final position
    let ratioH = (xConst - minCenterX) / max(1, geometry.availableWidth - geometry.barWidth)
    let minOriginY = geometry.minOriginY
    let ratioV = (yConst - minOriginY) / (geometry.maxOriginY - minOriginY)
    pwc?.log.verbose("Drag: Setting ratioH to: (\(xConst) - \(minCenterX)) / (\(geometry.availableWidth) - \(geometry.barWidth)) = \(ratioH)")

    // Save to prefs as future default
    Preference.set(ratioH, for: .controlBarPositionHorizontal)
    Preference.set(ratioV, for: .controlBarPositionVertical)
  }

  // MARK: - Mouse Events

  @MainActor
  func mouseDown(with event: NSEvent) {
    guard let pwc, let geometry = buildFloatingGeometry() else { return }

    pwc.log.verbose("FloatingOSC mouseDown")
    mousePosRelatedToView = view.convert(event.locationInWindow, from: nil)
    mouseDownLocationInWindow = event.locationInWindow
    let originInViewport = pwc.viewportView.convert(view.frame.origin, from: nil)
    let threshold = geometry.availableWidth * Constants.floatingControllerSnapToCenterThresholdMultiplier
    isAlignFeedbackSent = abs(originInViewport.x - (pwc.viewportView.frame.width - view.frame.width) / 2) <= threshold

    // Claim this now to signal to other things that nothing else should drag:
    pwc.currentDragObject = view
    // Reset flag
    minDragDistanceMet = false
  }

  @MainActor
  func mouseDragged(with event: NSEvent) {
    guard let mousePosRelatedToView,
          let mouseDownLocationInWindow,
          let pwc,
          let geometry = buildFloatingGeometry() else {
      return
    }
    assert(xConstraint != nil && yConstraint != nil, "xConstraint or yConstraint is nil!")

    if !minDragDistanceMet {
      let dragDistance = mouseDownLocationInWindow.distance(to: event.locationInWindow)
      guard dragDistance >= Constants.Window.minInitialDragThreshold else { return }
      pwc.log.verbose("FloatingOSC mouseDrag: minimum dragging distance was met")
      minDragDistanceMet = true
    }
    guard isDragging else { return }

    let currentLocInViewport = pwc.viewportView.convert(event.locationInWindow, from: nil)
    let xxx = currentLocInViewport.x - mousePosRelatedToView.x

    var newCenterX = (view.userInterfaceLayoutDirection == .rightToLeft ? geometry.maxCenterX - xxx : xxx + geometry.halfBarWidth)
    let newOriginY = currentLocInViewport.y - mousePosRelatedToView.y
    // stick to center
    if Preference.bool(for: .controlBarStickToCenter) {
      let xPosWhenCenter = geometry.centerX
      let threshold = geometry.availableWidth * Constants.floatingControllerSnapToCenterThresholdMultiplier
      pwc.log.trace("Floating OSC snap distanceToCenter=\(newCenterX - xPosWhenCenter) threshold=\(threshold)")
      if abs(newCenterX - xPosWhenCenter) <= threshold {
        newCenterX = xPosWhenCenter
        if !isAlignFeedbackSent {
          pwc.log.trace("Floating OSC sending haptic feedback for snap-to-center")
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

  @MainActor
  func mouseUp(with event: NSEvent) {
    guard let pwc, let geometry = buildFloatingGeometry()  else { return }
    if isDragging {
      pwc.log.verbose("FloatingOSC mouseUp: ending drag")
      pwc.currentDragObject = nil
    } else {
      pwc.log.verbose("FloatingOSC mouseUp")
    }

    if event.clickCount == 2 {
      // Double-clicked: center the OSC
      let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: geometry.centerX, originY: view.frame.origin.y)

      // apply position
      xConstraint.animateToConstant(xConst)
      yConstraint.animateToConstant(yConst)

      updateRatios(xConst: xConst, yConst: yConst, geometry)
    } else {
      updateRatios(xConst: xConstraint.constant, yConst: yConstraint.constant, geometry)
    }
  }

  @MainActor
  func cancelDrag() {
    guard let geometry = buildFloatingGeometry() else { return }
    updateRatios(xConst: xConstraint.constant, yConst: yConstraint.constant, geometry)
  }

  // MARK: - Coordinates in Viewport

  @MainActor
  fileprivate func buildFloatingGeometry() -> FloatingControlBarGeometry? {
    guard let pwc else { return nil }
    let currentLayout = pwc.currentLayout
    guard currentLayout.hasFloatingOSC else { return nil }
    // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
    let pwinGeo = currentLayout.isFullScreen ? pwc.fullScreenGeo() : pwc.windowedGeoForCurrentFrame()
    return FloatingControlBarGeometry(parentGeo: pwinGeo)
  }

  @MainActor
  fileprivate struct FloatingControlBarGeometry {
    let parentGeo: PWinGeometry
    let preferredBarWidth: CGFloat = FloatingControlBar.preferredBarWidth

    // "available" == space to move OSC within
    var availableWidthMinX: CGFloat {
      return parentGeo.insideBars.leading + FloatingControlBar.margin
    }

    var availableWidthMaxX: CGFloat {
      let viewportMaxX = parentGeo.viewportSize.width
      let trailingUsedSpace = parentGeo.insideBars.trailing + FloatingControlBar.margin
      return max(viewportMaxX - trailingUsedSpace, FloatingControlBar.margin + FloatingControlBar.minBarWidth)
    }

    var availableWidth: CGFloat {
      return availableWidthMaxX - availableWidthMinX
    }

    var barWidth: CGFloat {
      if availableWidth < preferredBarWidth {
        return availableWidth
      }
      return preferredBarWidth
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
      return FloatingControlBar.margin
    }

    var maxOriginY: CGFloat {
      let maxYWithoutTopBar = parentGeo.viewportSize.height - FloatingControlBar.barHeight - FloatingControlBar.margin
      let topBarHeight = parentGeo.insideBars.top
      return maxYWithoutTopBar - topBarHeight
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

} // end class FloatingControlBar

// MARK: - PlayerWindowController

extension PlayerWindowController {

  func addFloatingControlBarToViewportView() {
    guard !viewportView.containsSubview(controlBarFloating.view) else { return }

    log.verbose("Adding controlBarFloating to contentView")
    viewportView.addSubview(controlBarFloating.view)
    sortViewportViewSubviews()

    controlBarFloating.xConstraint?.isActive = false
    controlBarFloating.yConstraint?.isActive = false

    let newY = viewportView.bottomAnchor.constraint(equalTo: controlBarFloating.view.bottomAnchor, constant: 60)
    newY.identifier = "FloatingOSC-BtmY-Con"
    newY.priority = .defaultHigh
    controlBarFloating.yConstraint = newY

    let newX = controlBarFloating.view.centerXAnchor.constraint(equalTo: viewportView.leadingAnchor, constant: 330)
    newX.identifier = "FloatingOSC-CenterX-Con"
    newX.priority = .init(450)
    controlBarFloating.xConstraint = newX

    newY.isActive = true
    newX.isActive = true
  }

  func adjustFloatingControllerOrigin(for targetGeometry: PWinGeometry? = nil) {
    guard controlBarFloating.view.superview != nil else { return }

    let parentGeo = targetGeometry ?? windowedModeGeo
    guard parentGeo.isViewportShown else { return }
    controlBarFloating.moveToLocationRatio(parentGeo: parentGeo)
  }

}
