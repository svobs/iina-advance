//
//  PWin_Input.swift
//  iina
//
//  Created by Matt Svoboda on 2024-10-19.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

/// Mouse, Trackpad, Keyboard event handling.
/// For scroll wheel, see `PWin_ScrollWheel`.
extension PlayerWindowController {

  // MARK: - Keyboard event handling

  func handleKeyDown(event: NSEvent, normalizedMpvKey: String) -> Bool {
    let wasHandled = PluginInputManager.handle(
      input: normalizedMpvKey, event: .keyDown, player: player, arguments: keyEventArgs(event), handler: { [self] in
        return executeActionForKey(normalizedMpvKey: normalizedMpvKey)
      })

    return wasHandled
  }

  /// Returns true if handled (or ignored), false if not.
  /// If `fallbackAction` is given, always returns true.
  @discardableResult @MainActor
  func executeActionForKey(normalizedMpvKey: String, fallbackAction: ((PlayerCore) -> Void)? = nil) -> Bool {
    if let keyBinding = player.keyBindingContext.matchActiveKeyBinding(endingWith: normalizedMpvKey) {
      if keyBinding.normalizedMpvKey == StringConstants.anyUnicodeKey {
        player.mpv.queue.async { [self] in
          guard player.isActive else { return }
          // Matched ANY_UNICODE: just pass the key through to mpv. It will know what to do with it.
          player.mpv.command(MPVCommand.keypress, args: [normalizedMpvKey], checkError: false)
        }
        return true
      }
      // Matched regular key binding
      return handleKeyBinding(keyBinding)
    }

    if let fallbackAction {
      log.verbose("Executing fallback action for key \(normalizedMpvKey)")
      fallbackAction(player)
      return true
    }

    return false
  }

  func keyEventArgs(_ event: NSEvent) -> [[String: Any]] {
    [[
      "x": event.locationInWindow.x,
      "y": event.locationInWindow.y,
      "isRepeat": event.isARepeat
    ]]
  }

  /// Returns true if handled
  @discardableResult @MainActor
  func handleKeyBinding(_ keyBinding: KeyMapping) -> Bool {
    if keyBinding.isIgnored {
      // if "ignore", just swallow the event. Do not forward; do not beep
      log.verbose("Binding is ignored for key: \(keyBinding.normalizedMpvKey.quoted)")
      return true
    }

    guard let rawAction = keyBinding.rawAction, let action = keyBinding.action else {
      log.error("Expected key binding to have an mpv action, aborting: \(keyBinding)")
      return false
    }

    // Some script bindings will draw to the video area. We don't know which will, but
    // if the DisplayLink is not active the updates will not be displayed.
    // So start the DisplayLink temporily if not already running:
    videoView.enterAsynchronousMode()

    if keyBinding.isIINACommand {
      // - IINA command (exact)
      if let iinaCommand = IINACommand(rawValue: rawAction) {
        executeIINACommand(iinaCommand)
        return true
      } else if action.count >= 2, action[0] == "cycle",
                let iinaCmd = IINACommand(rawValue: action[1]),
                let prefKey = iinaCmd.prefKey {
        // Cycle pref key
        // Support booleans only for now
        if Preference.defaultPreference[prefKey] as? Bool != nil {
          let currentVal = Preference.bool(for: prefKey)
          let newVal = !currentVal
          log.debug("Toggling IINA pref \(prefKey.rawValue.quoted): \(currentVal.yn) → \(newVal.yn)")
          Preference.set(newVal, for: prefKey)
          return true
        }
      } else {
        log.error("Unrecognized IINA command: \(rawAction.quoted)")
        return false
      }
    }

    // - mpv command
    // execute the command
    switch action.first! {

    case MPVCommand.abLoop.rawValue:
      player.abLoop()
      return true

    case MPVCommand.quit.rawValue:
      // Initiate application termination. AppKit requires this be done from the main thread,
      // however the main dispatch queue must not be used to avoid blocking the queue as per
      // instructions from Apple. IINA must support quitting being initiated by mpv as the user
      // could use mpv's IPC interface to send the quit command directly to mpv. However the
      // shutdown sequence is cleaner when initiated by IINA, so we do not send the quit command
      // to mpv and instead trigger the normal app termination sequence.
      log.debug("Received MPVCommand.quit: calling NSApp.terminate")
      RunLoop.main.perform(inModes: [.common]) {
        NSApp.terminate(nil)
      }
      return true

    case MPVCommand.screenshot.rawValue,
      MPVCommand.screenshotRaw.rawValue:
      player.mpv.queue.async { [self] in
        player.screenshot(fromKeyBinding: keyBinding)
      }
      return true

    default:
      var returnValue: Int32
      let dispatchGroup = DispatchGroup()
      dispatchGroup.enter()

      returnValue = 0
      player.mpv.queue.async { [self] in
        returnValue = player.mpv.command(rawString: rawAction)
        dispatchGroup.leave()
      }
      let waitResult = dispatchGroup.wait(timeout: .now() + TimeConstants.keyDownHandlingTimeout)
      if waitResult == .timedOut {
        log.debug("Command timed out: \(rawAction.quoted)")
        return false
      }

      guard returnValue == 0 else {
        log.error("Return value \(returnValue) when executing key command \(rawAction.quoted)")
        return false
      }
    }

    return true
  }

  @MainActor
  private func executeIINACommand(_ cmd: IINACommand) {
    switch cmd {
    case .openFile:
      AppDelegate.shared.showOpenFileWindow(isAlternativeAction: false)
    case .openURL:
      AppDelegate.shared.openURL(self)
    case .flip:
      menuToggleFlip(self)
    case .mirror:
      menuToggleMirror(self)
    case .saveCurrentPlaylist:
      menuSavePlaylist(self)
    case .deleteCurrentFile:
      menuDeleteCurrentFile(self)
    case .deleteCurrentFileHard:
      menuDeleteCurrentFileHard(self)
    case .findOnlineSubs:
      menuFindOnlineSub(self)
    case .saveDownloadedSub:
      saveDownloadedSub(self)
    default:
      break
    }
  }

  // MARK: - Mouse / Trackpad event handling

  /// Called at window open. Set up mouse tracking areas
  func updateTrackingAreas() {
    guard let window = self.window, let cv = window.contentView else { return }

    removeTrackingAreas()

    var addedCount = 0
    if cv.trackingAreas.isEmpty {
      let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved]
      cv.addTrackingArea(NSTrackingArea(rect: cv.bounds, options: options, owner: self,
                                        userInfo: [TrackingArea.key: TrackingArea.playerWindow]))
      addedCount += 1
    }

    if playSlider.trackingAreas.isEmpty {
      let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate]
      playSlider.addTrackingArea(NSTrackingArea(rect: playSlider.bounds, options: options, owner: self,
                                                userInfo: [TrackingArea.key: TrackingArea.playSlider]))
      addedCount += 1
    }

    if volumeSlider.trackingAreas.isEmpty {
      let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate]
      volumeSlider.addTrackingArea(NSTrackingArea(rect: volumeSlider.bounds, options: options, owner: self,
                                                  userInfo: [TrackingArea.key: TrackingArea.volumeSlider]))
      addedCount += 1
    }

    log.verbose("Added \(addedCount) tracking areas")
  }

  func removeTrackingAreas() {
    var removedCount = 0
    for view in [playSlider, volumeSlider, window?.contentView] {
      if let view {
        for area in view.trackingAreas {
          view.removeTrackingArea(area)
          removedCount += 1
        }
      }
    }
    log.verbose("Removed \(removedCount) tracking areas")
  }

  /// Checks if an object is marked as being dragged, and if it is, whether the drag is still valid.
  /// Cancels drag if it is no longer valid.
  /// Returns: `true` if a drag is in progress and it is valid; `false` if no drag or invalid drag was cleaned up.
  /// See also: `mouseDown` logic
  func isValidDragInProgress() -> Bool {
    guard let currentDragObject else { return false }
    if isLeftMouseButtonDown {
      return true
    }

    // Window will not receive mouseUp events from outside of window, so previous drag may not have finished.
    // But for our our draggable objects, there is no need to drag outside of window, so we will treat as a cancelled drag.
    log.debug("Left mouse btn is not down, but found currentDragObject \(currentDragObject.idString.quoted). Assuming mouseUp was outside of window; canceling drag")
    if let cancellableObject = currentDragObject as? DraggableObject {
      cancellableObject.cancelDrag()
    }
    self.currentDragObject = nil
    return false
  }

  /// This method is provided soly for invoking plugin input handlers.
  func informPluginMouseDragged(with event: NSEvent) {
    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDrag, player: player,
      arguments: mouseEventArgs(event)
    )
  }

  fileprivate func mouseEventArgs(_ event: NSEvent) -> [[String: Any]] {
    return [[
      "x": event.locationInWindow.x,
      "y": event.locationInWindow.y,
      "clickCount": event.clickCount,
      "pressure": event.pressure
    ] as [String : Any]]
  }

  func isMouseEventInsideDisabledView(_ event: NSEvent) -> Bool {
    isMouseEvent(event, inAnyOf: mouseActionDisabledViews)
  }

  func isMouseEvent(_ event: NSEvent, inAnyOf views: any Collection<NSView?>) -> Bool {
    return isPoint(event.locationInWindow, inAnyOf: views)
  }

  func isPoint(_ pointInWindow: NSPoint, inAnyOf views: any Collection<NSView>) -> Bool {
    return views.reduce(false, { (result, view) in
      return result || view.isMousePoint(view.convert(pointInWindow, from: nil), in: view.bounds)
    })
  }

  func isPoint(_ pointInWindow: NSPoint, inAnyOf views: any Collection<NSView?>) -> Bool {
    return views.filter { $0 != nil }.reduce(false, { (result, view) in
      return result || view!.isMousePoint(view!.convert(pointInWindow, from: nil), in: view!.bounds)
    })
  }

  /// Returns the first view found in `views` for which the given mouse event's point location lands inside its bounds, and for
  /// which neither it nor any of its ancestors are hidden.
  ///
  /// This method is meant as a substitute from `NSView.hitTest`, which seems to only return the first responder.
  fileprivate func visibleViewForMouseEvent(_ event: NSEvent, in views: [NSView?]) -> NSView? {
    let pointInWindow = event.locationInWindow
    for view in views {
      guard let view else { continue }
      let viewFrame = view.frameInWindowCoords
      if view.isMousePoint(pointInWindow, in: viewFrame) {
        if !view.isHiddenOrHasHiddenAncestor {
          return view
        }
      }
    }
    return nil
  }

  /// Being called to perform single click action after timeout.
  ///
  /// - SeeAlso: mouseUp(with:)
  @objc internal func performMouseActionLater(_ timer: Timer) {
    guard let action = timer.userInfo as? Preference.MouseClickAction else { return }
    performMouseAction(action)
  }

  override func pressureChange(with event: NSEvent) {
    // Prevent from triggering during a drag
    guard currentDragObject == nil else { return }

    log.trace("PressureChange: stage=\(event.stage) stageTransition=\(event.stageTransition)")
    if !isCurrentPressInSecondStage && event.stage == 2 {
      performMouseAction(Preference.enum(for: .forceTouchAction))
      isCurrentPressInSecondStage = true
    } else if event.stage == 1 {
      isCurrentPressInSecondStage = false
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard event.eventNumber != lastMouseDownEventID else { return }
    lastMouseDownEventID = event.eventNumber
    log.verbose("PWin MouseDown @ \(event.locationInWindow) clickCount=\(event.clickCount) eventNum=\(event.eventNumber)")

    wasKeyWindowAtMouseDown = lastKeyWindowStatus
    mouseDownLocation = NSEvent.mouseLocation
    mouseDownLocationInWindow = event.locationInWindow
#if ENABLE_CUSTOM_WINDOW_DRAG  // see `performWindowDrag` in PWin_Input.swift
    windowFrameAtMouseDown = window!.frame
#endif

    if let currentDragObject {
      // Window will not receive mouseUp events from outside of window, so previous drag may not have finished.
      // But for our our draggable objects, there is no need to drag outside of window, so we will treat as a cancelled drag.
      log.debug("PWin MouseDown: found currentDragObject \(currentDragObject.idString.quoted). Assuming mouseUp was outside of window; canceling drag")
      if let cancellableObject = currentDragObject as? DraggableObject {
        cancellableObject.cancelDrag()
      }
      self.currentDragObject = nil
    }

    if !speedLabel.isHidden, isMouseEvent(event, inAnyOf: [speedLabel]) {
      log.verbose("PWin MouseDown: user clicked on speedLabel; treating as playButton")
      playButtonAction(self)
    } else if !controlBarFloating.view.isHidden, isMouseEvent(event, inAnyOf: [controlBarFloating.view]) {
      log.error("PWin MouseDown: ignoring; should be handled by controlBarFloating")
      return
    } else if let cbView = cropSettingsView?.cropBoxView, isInInteractiveMode && isMouseEvent(event, inAnyOf: [cbView]) {
      log.error("PWin MouseDown: ignoring; should be handled by CropBoxView")
      return
    } else if startResizingSidebar(with: event) {
      // Started resize if applicable. With either sidebar, this will always be dragging the playlist panel
      currentDragObject = playlistView.view
      return
    } else {
      dragWindowIfQualifying(from: event)
    }

    hideCursorTimer.restart()

    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
    // we don't call super here because before adding the plugin system,
    // PlayerWindowController didn't call super at all
  }

  private func dragWindowIfQualifying(from event: NSEvent) {
    guard !isFullScreen else { return }
    if !isDragging, let mouseDownLocationInWindow {
      /// Require that the user must drag the cursor at least a small distance for it to start a "drag" (`isDragging==true`)
      /// The user's action will only be counted as a click if `isDragging==false` when `mouseUp` is called.
      /// (Apple's trackpad in particular is very sensitive and tends to call `mouseDragged()` if there is even the slightest
      /// roll of the finger during a click, and the distance of the "drag" may be less than `minimumInitialDragDistance`)
      let dragDistance = mouseDownLocationInWindow.distance(to: event.locationInWindow)
      guard dragDistance > Constants.Window.minInitialDragThreshold else { return }

      log.verbose("PWin MouseDrag: minimum dragging distance was met (\(Double(dragDistance).twoDecimalPlaces)")
      isDragging = true
    }

    performWindowDrag(with: event)
  }

  private func performWindowDrag(with event: NSEvent) {
    guard let window else { return }

#if ENABLE_CUSTOM_WINDOW_DRAG
    // TODO: this mostly works except for some corner cases when dragging from one screen to another.
    // TODO: Expand on this to add ability to keep video entirely on screen at all times.
    guard let mouseDownLocation, let windowFrameAtMouseDown else { return }

    let currentLocation = NSEvent.mouseLocation
    // Adapted from: https://stackoverflow.com/a/1946223
    let dX = (currentLocation.x - mouseDownLocation.x)
    let dY = (currentLocation.y - mouseDownLocation.y)
    log.verbose("PWin MouseDrag: \(dX), \(dY)")
    var newOrigin = NSPoint(x: windowFrameAtMouseDown.origin.x + dX,
                            y: windowFrameAtMouseDown.origin.y + dY)

    // Don't let window get dragged up under the menu bar
    let windowFrame = window.frame
    let windowScreen = window.screen
    if let screenFrame = windowScreen?.visibleFrame, newOrigin.y+windowFrame.size.height > screenFrame.origin.y+screenFrame.size.height {
      newOrigin.y = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height)
    }
    window.setFrameOrigin(newOrigin)
#else
    window.performDrag(with: event)
#endif

    informPluginMouseDragged(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    log.trace("PWin MouseDragged @ \(event.locationInWindow) obj=\(currentDragObject?.idString ?? "nil")")

    hideCursorTimer.cancel()
    if let currentDragObject {
      currentDragObject.mouseDragged(with: event)
      return
    }

    dragWindowIfQualifying(from: event)
  }

  override func mouseUp(with event: NSEvent) {
    guard event.eventNumber != lastMouseUpEventID else { return }
    lastMouseUpEventID = event.eventNumber
    log.verbose("PWin MouseUp @ \(event.locationInWindow) clickCount=\(event.clickCount) dragging=\(isDragging.yn) eventNum=\(event.eventNumber)")

    // Always do these:
    hideCursorTimer.restart()

    // If WindowDidChangeScreen during window drag, the resize event won't appear until after mouseUp, which can
    // be an arbitrary amount of time after the screen change. So make sure to deny it now, with some fuzz depending on
    // when the event gets processed.
    // FIXME: there should be a way to search the queued events and deny the resize event proactively! Check Apple docs
    if pendingResizeForScreenChange {
      restartWindowResizeDenialPeriod("mouseUp-pendingResizeForScreenChange")
      pendingResizeForScreenChange = false
    }

    // Check these in the same order as in mouseDown, to avoid going to unexpected states
    if let currentDragObject {
      defer {
        self.currentDragObject = nil
      }
      log.verbose("PWin MouseUp: finished drag of object")
      currentDragObject.mouseUp(with: event)
      return
    } else if isDragging {
      // if it's a mouseup after dragging window
      log.verbose("PWin MouseUp: finished drag of window")
      isDragging = false
      return
    }

    // Else: if it's a mouseup after clicking
    let isSingleClick = event.clickCount == 1
    let isDoubleClick = event.clickCount == 2

    if isDoubleClick {
      let titleBarMinY = window!.frame.height - Constants.standardTitleBarHeight
      if !isFullScreen && (event.locationInWindow.y >= titleBarMinY) {
        if let userDefault = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
          log.verbose("Double-click occurred in title bar. Executing \(userDefault.quoted)")
          if userDefault == "Minimize" {
            window?.performMiniaturize(nil)
          } else if userDefault == "Maximize" {
            window?.performZoom(nil)
          }
          return
        } else {
          log.verbose("Double-click occurred in title bar, but no action for AppleActionOnDoubleClick")
        }
      } else {
        log.verbose("Double-click did not occur inside title bar (minY: \(titleBarMinY)) or is full screen (\(isFullScreen))")
      }
    }

    guard !isMouseEventInsideDisabledView(event) else {
      log.verbose("PWin MouseUp: click occurred in a disabled view; ignoring")
      super.mouseUp(with: event)
      return
    }

    /// Single click. Note that `event.clickCount` will be 0 if there is at least one call to `mouseDragged()`,
    /// but we will only count it as a drag if `isDragging==true`
    if isSingleClick {
      if hideSidebarsOnClick() {
        log.verbose("PWin MouseUp: hiding sidebars")
        return
      }
    }

    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: { [self] in
        let doubleClickAction: Preference.MouseClickAction = Preference.enum(for: .doubleClickAction)
        // default handler
        if isSingleClick {
          let singleClickAction: Preference.MouseClickAction = Preference.enum(for: .singleClickAction)
          if singleClickAction == .hideOSC && !wasKeyWindowAtMouseDown {
            // Don't hide OSC
            log.verbose("Window was not key at mouseDown; skipping mouseAction: \(singleClickAction)")
            return false
          }
          if doubleClickAction == .none {
            performMouseAction(singleClickAction)
          } else {
            singleClickTimer = Timer.scheduledTimer(timeInterval: NSEvent.doubleClickInterval, target: self, selector: #selector(performMouseActionLater), userInfo: singleClickAction, repeats: false)
          }
        } else if isDoubleClick {
          if let timer = singleClickTimer {
            timer.invalidate()
            singleClickTimer = nil
          }
          performMouseAction(doubleClickAction)
        }
        return true
      })
  }

  override func otherMouseDown(with event: NSEvent) {
    hideCursorTimer.restart()
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    log.verbose("PWin OtherMouseUp!")
    hideCursorTimer.restart()
    guard !isMouseEventInsideDisabledView(event) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.otherMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
        if event.type == .otherMouseUp {
          self.performMouseAction(Preference.enum(for: .middleClickAction))
        } else {
          super.otherMouseUp(with: event)
        }
        return true
      })
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// AppKit contains special handling for [rightMouseDown](https://developer.apple.com/documentation/appkit/nsview/event_handling/1806802-rightmousedown) having to do with contextual menus.
  /// Even though the documentation indicates the event will be passed up the responder chain, the event is not being received by the
  /// window controller. We are having to catch the event in the view. Because of that we do not call the super method and instead
  /// return to the view.`
  override func rightMouseDown(with event: NSEvent) {
    guard event.eventNumber != lastRightMouseDownEventID else { return }
    lastRightMouseDownEventID = event.eventNumber
    log.verbose("PWin RightMouseDown!")

    hideCursorTimer.restart()
    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
  }

  override func rightMouseUp(with event: NSEvent) {
    guard event.eventNumber != lastRightMouseUpEventID else { return }
    lastRightMouseUpEventID = event.eventNumber
    log.verbose("PWin RightMouseUp!")
    hideCursorTimer.restart()
    guard !isMouseEventInsideDisabledView(event) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
        self.performMouseAction(Preference.enum(for: .rightClickAction))
        return true
      })
  }

  func performMouseAction(_ action: Preference.MouseClickAction) {
    log.verbose("Performing mouseAction: \(action)")
    switch action {
    case .pause:
      player.togglePause()
    case .fullscreen:
      toggleWindowFullScreen()
    case .hideOSC:
      hideFadeableViewsAndCursor()
    case .togglePIP:
      menuTogglePIP(self)
    case .abLoop:
      player.abLoop()
    case .resetSpeed:
      player.setSpeed(1.0)
    case .contextMenu:
      showContextMenu()
    default:
      break
    }
  }

  override func mouseEntered(with event: NSEvent) {
    guard !isValidDragInProgress() else { return }
    guard !isAnimatingLayoutTransition, !isApplyingPWinGeo else { return }
    guard !isInInteractiveMode else { return }

    guard let area = event.trackingArea?.userInfo?[TrackingArea.key] as? TrackingArea else {
      log.warn("No data for tracking area")
      return
    }

    // Fadeable views
    switch area {
    case .playerWindow:
      log.trace("MouseEntered into playerWindow")
      if player.isInMiniPlayer {
        miniPlayer.loadIfNeeded()
        miniPlayer.showOrHideControls()
      } else {
        showFadeableViewsForMouseLocation(mouseLocationInWindow)
      }
    default:
      log.trace("MouseEntered: unhandled tracking area")
      break
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard !isValidDragInProgress() else { return }
    guard !isAnimatingLayoutTransition, !isApplyingPWinGeo else { return }
    guard let area = event.trackingArea?.userInfo?[TrackingArea.key] as? TrackingArea else {
      log.warn("MouseExited: no data for tracking area!")
      return
    }

    switch area {
    case .playerWindow:
      // reset after moved out of window
      isMomentumScrollingAllowed = false
      log.trace("MouseExited from playerWindow")

      // Cursor
      if !currentLayout.mode.mustShowCursorAlways {
        // Show cursor if not already shown
        // FIXME: only if mouse is not inside any window
        setCursorToNormalAlwaysShown()
      }

      if player.isInMiniPlayer {
        miniPlayer.loadIfNeeded()
        miniPlayer.showOrHideControls()
      } else if Preference.bool(for: .hideFadeableViewsWhenOutsideWindow) {
        // Hide fadeable views if configured
        hideFadeableViews()
      } else {
        // Closes loophole in case cursor hovered over OSC before exiting (in which case timer was destroyed)
        fadeableViews.hideTimer.restart()
      }
    default:
      log.trace("MouseExited: unhandled tracking area")
      break
    }
  }

  override func mouseMoved(with event: NSEvent) {
    // Disable hover actions if first mouse is disabled & window not in focus:
    guard let window, (window.isKeyWindow || Preference.bool(for: .videoViewAcceptsFirstMouse)) else { return }

    guard !isValidDragInProgress() else { return }
    mouseDidMoveInWindow()
  }

  func mouseDidMoveInWindow() {
    guard !isScrollingOrDraggingPlaySlider, !isScrollingOrDraggingVolumeSlider else { return }
    guard !isAnimatingLayoutTransition, !isApplyingPWinGeo else { return }
    assert(!isValidDragInProgress(), "Must check isValidDragInProgress() before calling mouseDidMoveInWindow()!")
    // Do not use `event.locationInWindow`: it can be very stale
    let pointInWindow = mouseLocationInWindow

    log.trace("MouseDidMoveInWindow @ \(pointInWindow)")

    if let customTitleBar {
      // Enable show/hide of icons when hovering over traffic light buttons, mimicking native title bar
      if isMouseCurrentlyInside(anyOf: customTitleBar.trafficLightButtons) {
        customTitleBar.isHoveringOverTrafficLights = true
      } else {
        customTitleBar.isHoveringOverTrafficLights = false
      }
    }

    // Update hover effect(s)
    if !isInInteractiveMode {
      // Show Seek Preview on mouse hover. The check at the start of this func will return if in an "active seek"
      // preview to ensure that the "hover" preview here will not activate:
      refreshSeekPreviewAsync(forPointInWindow: pointInWindow)
      // Check if hovering over volume slider, and add/remove its hover effect
      volumeSliderCell.refreshVolumeSliderHoverEffect()
    }

    // Update mouse cursor
    if !currentLayout.mode.mustShowCursorAlways {

      // FIXME: need to use global logic instead
      if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: pointInWindow) ||
          isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: pointInWindow) {
        /// Hovering within area which can resize a sidebar? Set or unset the cursor to `resizeLeftRight`
        applyCustomCursor(.resizing_BothDirections)
      } else if isPoint(pointInWindow, inAnyOf: [volumeSlider]) {
        applyCustomCursor(.hoveringInSlider)
      } else if isPointInPlaySliderAndNotOtherViews(pointInWindow: pointInWindow) {
        applyCustomCursor(.hoveringInSlider)
      } else {
        // TODO: finish implementing hide cursor
        /*if player.shouldAlwaysHideCursor {
         log.verbose("Hiding cursor")
         hideCursorTimer.cancel()
         NSCursor.hide()
         } else {*/
        applyCustomCursor(.normalCursor)
        NSCursor.setHiddenUntilMouseMoves(false) // show if not shown
                                                 // Always hide after timeout even if OSD fade time is longer
        hideCursorTimer.restart()
        //      }
      }
    }

    // Fadeable views
    if player.isInMiniPlayer {
      /// Show Controller and window controls if hovering over either `musicModeControlBarView` or `viewportView`.
      miniPlayer.loadIfNeeded()
      miniPlayer.showOrHideControls()
    } else {
      showFadeableViewsForMouseLocation(pointInWindow)
    }
  }

  // Do not show hover cursor if over a button or other view which overlaps PlaySlider.
  func isPointInPlaySliderAndNotOtherViews(pointInWindow: NSPoint) -> Bool {
    if isPoint(pointInWindow, inAnyOf: [playSlider]) {
      let isOSCTwoRowViewAttached = oscTwoRowView.superview != nil
      if isOSCTwoRowViewAttached {
        if let frontmostView = findView(atPoint: pointInWindow, fromParent: oscTwoRowView.hStackView),
           frontmostView != oscTwoRowView.hStackView, frontmostView != oscTwoRowView.centralSpacerView {
          // Skip over duration if it is clickable
          if let durationField = frontmostView as? DurationDisplayTextField, durationField.handlesMouseDown {
            return false
          }
          // But treat non-clickable text fields as part of PlaySlider if they click through to it
          return frontmostView as? ClickThroughTextField != nil
        }
      }
      return true
    }
    return false
  }

  func findView(atPoint pointInWindow: NSPoint, fromParent parentViewParam: NSView? = nil) -> NSView? {
    let parentView: NSView
    if let parentViewParam {
      parentView = parentViewParam
    } else if let contentView = window?.contentView {
      parentView = contentView
    } else {
      return nil
    }

    for view in parentView.subviews {
      if view.superview != nil && !view.isHidden && view.alphaValue > 0.0 {
        if view.isInsideViewFrame(pointInWindow: pointInWindow) {
          return findView(atPoint: pointInWindow, fromParent: view)
        }
      }
    }

    return parentView
  }

  func visibleViewAtPoint(_ pt: NSPoint) -> NSView? {
    var visibleView: NSView?
    visibleView = findView(atPoint: pt, fromParent: nil)
    return visibleView
  }

  func isMouseCurrentlyInside(view: NSView) -> Bool {
    return isPoint(mouseLocationInWindow, inAnyOf: [view])
  }

  func isMouseCurrentlyInside(anyOf views: [NSView]) -> Bool {
    return isPoint(mouseLocationInWindow, inAnyOf: views)
  }

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    magnificationHandler.handleMagnifyGesture(recognizer: recognizer)
  }

  @objc func handleRotationGesture(recognizer: NSRotationGestureRecognizer) {
    rotationHandler.handleRotationGesture(recognizer: recognizer)
  }

  // MARK: - Cursor

  func setCursorToNormalAlwaysShown() {
    hideCursorTimer.cancel()  // Always hide after timeout even if OSD fade time is longer
    applyCustomCursor(.normalCursor)
    NSCursor.setHiddenUntilMouseMoves(false) // show if not shown
  }

  @MainActor
  func applyCustomCursor(_ newCursorType: CursorType, force: Bool = false) {
    guard (customCursor != .disappearingItem) || force else {
      log.verbose("Ignoring custom cursor request: disappearingItem cursor is set")
      return
    }
    let newCursor: NSCursor
    switch newCursorType {
    case .normalCursor:
      if customCursor != .normalCursor {
        log.verbose("Setting cursor back to normal")
        NSCursor.current.pop()
        customCursor = .normalCursor
      }
      return
    case .resized_AtLeftMin:
      if #available(macOS 15.0, *) {
        newCursor = NSCursor.columnResize(directions: .right)
      } else {
        newCursor = NSCursor.resizeRight
      }
    case .resized_AtRightMax:
      if #available(macOS 15.0, *) {
        newCursor = NSCursor.columnResize(directions: .left)
      } else {
        newCursor = NSCursor.resizeLeft
      }
    case .resizing_BothDirections:
      if #available(macOS 15.0, *) {
        newCursor = NSCursor.columnResize(directions: .all)
      } else {
        newCursor = NSCursor.resizeLeftRight
      }
    case .hoveringInSlider:
      newCursor = NSCursor.pointingHand
    case .disappearingItem:
      newCursor = .disappearingItem
    }

    // Not sure if this is a kludge, but it works great so far for MacOS 15.3.
    // - Need to push at least 1 cursor onto the stack, just so we can get the previous cursor back with NSCursor.current.pop().
    // - Cannot keep pushing onto stack - it destroys performance.
    // - Doesn't work well with sliders though - they keep resetting to pointer cursor during hover (but only while window is main).
    // The solution Apple seems to prefer for hover is to set up for .cursorUpdate events. But those only work when the window is main!
    // This solution works for any non-main window while the app is frontmost, and works for regular dead NSViews for main window.
    // Combined, using cursorUpdate works for sliders when window is main, and this method picks up the work for them when non-main.
    if customCursor == .normalCursor {
      log.verbose("Pushing cursor to \(newCursorType)")
      newCursor.push()
    } else if (customCursor != newCursorType) || (NSCursor.current != newCursor) {
      // There seems to be a race condition in Apple's code which causes push() or set()
      // to get ignored, so we cannot assume they succeeded.
      // Partial workaround: add the extra check against NSCursor.current above.
      log.verbose("Setting cursor to \(newCursorType)")
      newCursor.set()
    }
    customCursor = newCursorType
  }

  // Currently only used for hover over sliders
  override func cursorUpdate(with event: NSEvent) {
    guard isPointInPlaySliderAndNotOtherViews(pointInWindow: event.locationInWindow) ||
        isPoint(event.locationInWindow, inAnyOf: [volumeSlider]) else {
      return
    }
    log.trace("CursorUpdate: applying .hoveringInSlider")
    applyCustomCursor(.hoveringInSlider)
  }

  /// Only hides cursor if in full screen or windowed (non-interactive, non-music) modes, and only if mouse is within
  /// bounds of the window's real estate.
  @objc func hideCursorAsConfigured() {
    guard let window else { return }
    guard !currentLayout.mode.mustShowCursorAlways else { return }

    switch currentLayout.mode {
    case .windowedNormal:
      let isCursorInWindow = NSPointInRect(NSEvent.mouseLocation, window.frame)
      guard isCursorInWindow else { return }
    case .fullScreenNormal:
      let isCursorInScreen = NSPointInRect(NSEvent.mouseLocation, bestScreen.visibleFrame)
      guard isCursorInScreen else { return }
    case .musicMode, .windowedInteractive, .fullScreenInteractive:
      // see guard above
      assert(false, "Mode \(currentLayout.mode) must always show cursor! Should not see this.")
      return
    }
    // IMPORTANT: We *must* ensure that NSCursor.setHiddenUntilMouseMoves is called inside an animation task!
    // Otherwise it will sometimes fail to hide the cursor. (Speculation: a race condition inside its private
    // code may cause any NSCursor API call to fail if overlapping with any other).
    // FIXME: this still isn't reliable in full screen when OSC auto-hide is disabled
    animationPipeline.submitInstantTask{ [self] in
      guard !isPoint(mouseLocationInWindow, inAnyOf: mouseActionDisabledViews) else {
        log.trace("Not hiding cursor: mouse is in a disabled view")
        return
      }

      guard player.canHideCursor else {
        log.trace("Not hiding cursor")
        return
      }

      log.trace("Hiding cursor until mouse moves")
      NSCursor.setHiddenUntilMouseMoves(true)
    }
  }

}
