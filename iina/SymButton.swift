//
//  SymButton.swift
//  iina
//
//  Created by Matt Svoboda on 2024-12-22.
//

/// Replacement for `NSButton` (which seems to be de-facto deprecated) because that class does not support using symbol animations in newer versions of MacOS.
@MainActor
class SymButton: NSImageView, @MainActor NSAccessibilityButton, DraggableObject {
  var actionSymbolEffectFunc: (@MainActor (SymButton) -> Void) = SymButton.bounceEffectFunc

  /// Does nothing
  static func nullEffectFunc(_ btn: SymButton) {}

  static func bounceEffectFunc(_ btn: SymButton) {
    btn.addSymbolEffect(.bounce.down.wholeSymbol, options:
        .speed(Constants.symButtonImageTransitionSpeed)
        .nonRepeating, animated: true)
  }

  static func rotateEffectFunc(_ btn: SymButton) {
    if #available(macOS 15.0, *) {
      btn.addSymbolEffect(.rotate.byLayer, options:
          .speed(Constants.symButtonImageTransitionSpeed)
          .nonRepeating, animated: true)
    }
    // Also bounce, to reinforce "clicky" feel
    bounceEffectFunc(btn)
  }

  var regularColor: NSColor? = nil
  var highlightColor: NSColor? = .controlTextColor

  var enableAcceleration: Bool = false
  var pressureStage: Int = 0 {
    willSet {
      if pressureStage != newValue {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
      }
    }
  }

  enum ReplacementEffect {
    case downUp
    case upUp
    case offUp
  }

  init(id: String? = nil) {
    super.init(frame: .zero)
    if let id {
      self.idString = id
    }
    configureSelf()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureSelf()
  }

  /// Similar to `NSButton`'s `init` method.
  init(id: String? = nil, image: NSImage, target: AnyObject? = nil, action: Selector? = nil) {
    super.init(frame: .zero)
    if let id {
      self.idString = id
    }
    self.wantsLayer = true
    configureSelf()
    self.image = image
    self.target = target
    self.action = action
  }

  func configureSelf() {
    translatesAutoresizingMaskIntoConstraints = false
    imageScaling = .scaleProportionallyUpOrDown
    imageAlignment = .alignCenter
    refusesFirstResponder = false
  }

  fileprivate func pwc(from event: NSEvent) -> PlayerWindowController? {
    if let pwc = super.pwc {
      return pwc
    }

    let isInNativeFullScreen = NSApp.presentationOptions.contains(.fullScreen)
    if isInNativeFullScreen {
      // If this button was in the title bar, when the window goes to native full screen it will be moved to a separate faux window!
      // Try to find pwc if it was set as the target...
      if let pwc = target as? PlayerWindowController {
        return pwc
      } else {
        Logger.log.warn("Unable to find PlayerWindowController for SymButton \(idString) while in native full screen!")
      }
    }
    return nil
  }

  // MARK: - Mouse Input

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard action != nil else {
      super.mouseDown(with: event)
      return
    }

    guard let pwc = pwc(from: event) else { return }

    /// Setting this will cause PlayerWindowController to forward `mouseDragged` & `mouseUp` events to this object even when out of bounds
    pwc.currentDragObject = self
    let isInsideBounds = updateHighlight(from: event)
    pwc.log.verbose("SymButton \(idString.quoted): mouseDown insideBounds=\(isInsideBounds.yn)")

    if enableAcceleration && isInsideBounds {
      pressureStage = 1
      sendAction(action, to: target)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard action != nil else {
      super.mouseDragged(with: event)
      return
    }
    let isInsideBounds = updateHighlight(from: event)
    pwc?.log.trace("SymButton \(idString.quoted): mouseDragged insideBounds=\(isInsideBounds.yn)")
  }

  override func mouseUp(with event: NSEvent) {
    guard action != nil else {
      super.mouseUp(with: event)
      return
    }
    let isInsideBounds = isInsideBounds(event)
    guard let pwc = pwc(from: event) else { return }
    pwc.log.verbose("SymButton \(idString.quoted): mouseUp insideBounds=\(isInsideBounds.yn)")
    if isInsideBounds {
      pressureStage = 0
      pwc.currentDragObject = nil

      if IINAAnimation.isAnimationEnabled {
        actionSymbolEffectFunc(self)
      }

      pwc.player.log.verbose("Calling action: \(action?.description ?? "nil")")
      sendAction(action, to: target)
      updateHighlight(isInsideBounds: false)
    }
  }

  func cancelDrag() {
    pwc?.log.verbose("SymButton \(idString.quoted): cancelling drag")
    updateHighlight(isInsideBounds: false)
  }

  override func pressureChange(with event: NSEvent) {
    guard enableAcceleration else { return }
    let pseudoStage = Int(event.pressure * 5)
    guard let pwc = pwc(from: event) else { return }
    pwc.player.log.trace("SymButton \(idString.quoted): PressureChange: stage=\(event.stage) stageTransition=\(event.stageTransition) pressure=\(event.pressure) pseudoStage=\(pseudoStage)")
    pressureStage = pseudoStage
    sendAction(action, to: target)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    // Emulate NSButton, which always accepts first mouse
    true
  }

  override func accessibilityPerformPress() -> Bool {
    sendAction(action, to: target)
  }

  override func accessibilityLabel() -> String? {
    return toolTip
  }

  // MARK: - Highlight & Shadow

  @discardableResult
  private func updateHighlight(from event: NSEvent) -> Bool {
    guard let pwc = pwc(from: event) else { return false }
    let isInsideBounds = pwc.currentDragObject == self && isInsideViewFrame(pointInWindow: event.locationInWindow)
    updateHighlight(isInsideBounds: isInsideBounds)
    return isInsideBounds
  }

  func updateHighlight(isInsideBounds: Bool) {
    if isInsideBounds {
      contentTintColor = highlightColor
    } else {
      contentTintColor = regularColor
    }
  }

  func setGlowForTitleBar(enabled: Bool) {
    if enabled {
      guard shadow == nil else { return }
      addShadow(blurRadiusConstant: 0.3, xOffsetConstant: 0, yOffsetConstant: 0, color: .controlAccentColor)
    } else {
      shadow = nil
    }
  }

  /// Sets current tint as a side effect! Do not use if currently between mouseDown & mouseUp.
  func setColors(for colorScheme: Preference.PanelColorScheme, _ controlType: ControlTypeForShadow = .button) {
    switch colorScheme {
    case .clearGradient:
      regularColor = .controlForClearBG
      highlightColor = .white
      updateHighlight(isInsideBounds: false)
    case .clearGlass:
      regularColor = .controlForClearBG
      highlightColor = .white
      updateHighlight(isInsideBounds: false)
    default:
      regularColor = nil
      highlightColor = .controlTextColor
      updateHighlight(isInsideBounds: false)
    }
    addShadow(colorScheme, controlType)
  }

  // MARK: - Misc.

  private func isInsideBounds(_ event: NSEvent) -> Bool {
    guard let pwc = pwc(from: event) else { return false }
    return pwc.currentDragObject == self && isInsideViewFrame(pointInWindow: event.locationInWindow)
  }

  /// Updates this button's image with the given image. Will use the given animation effect if the user's
  /// version of MacOS supports it & motion reduction is not enabled.
  func replaceSymbolImage(with newImage: NSImage?, effect: ReplacementEffect? = nil) {
    guard let newImage, newImage != image else { return }
    if #available(macOS 15.0, *), let effect, IINAAnimation.isAnimationEnabled {
      let nativeEffect: ReplaceSymbolEffect
      switch effect {
      case .downUp:
        nativeEffect = .replace.downUp
      case .upUp:
        nativeEffect = .replace.upUp
      case .offUp:
        nativeEffect = .replace.offUp
      }
      setSymbolImage(newImage, contentTransition: nativeEffect, options:
          .speed(Constants.symButtonImageTransitionSpeed)
          .nonRepeating)
    } else {
      image = newImage
    }
  }

}
