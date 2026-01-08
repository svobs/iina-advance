//
//  PlayerWindow.swift
//  iina
//
//  Created by Collider LI on 10/1/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

final class PlayerWindow: NSWindow {
  var useZeroDurationForAnimationResize = false
  private var keyDownCount: Int = 0
  private var keyUpCount: Int = 0

  /* // May be useful for debugging / sleuthing at some point
  override func responds(to aSelector: Selector!) -> Bool {
    Logger.log.verbose("SELECTOR: \(aSelector.description)")
    return super.responds(to: aSelector)
  }*/

  var pwc: PlayerWindowController? {
    return windowController as? PlayerWindowController
  }

  var log: any Logger.Subsystem {
    return (windowController as! PlayerWindowController).player.log
  }

  var isCustomWindowStyle: Bool {
    return !styleMask.contains(.titled)
  }

  private var isFullScreen: Bool { pwc?.isFullScreen ?? true }
  private var isMusicMode: Bool { pwc?.isInMiniPlayer ?? true }

  // MARK: setFrame

  override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
    let time: TimeInterval
    if useZeroDurationForAnimationResize {
      time = 0.0
    } else {
      time = super.animationResizeTime(newFrame)
    }
    return time
  }

  // MARK: - Key event handling

  // FIXME: Arrow key navigation still doesn't work for some text fields!
  override func keyDown(with event: NSEvent) {
    assert(DispatchQueue.isExecutingIn(.main))
    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)
    if !event.isARepeat {
      keyDownCount += 1
    }
    log.verbose("KEYDN #\(keyDownCount)\(event.isARepeat ? " (repeat)" : ""): \(normalizedKeyCode.quoted)")

    guard let pwc else { log.fatalError("No PlayerWindowController for PlayerWindow.keyDown()!") }

    if processForImmediateView(keyCode: keyCode, pwc) {
      return
    }
    pwc.updateUI(pullUpdatesFromMpv: true)  // Call explicitly to make sure it gets attention

    // Menu item key equivalents take priority
    if menu?.performKeyEquivalent(with: event) == true {
      log.verbose("KeyDown: was handled by menu item; returning")
      return
    }

    let staticMenuItemMappings = AppInputConfig.staticMenuItemMappings
    if staticMenuItemMappings.contains(where: { $0.normalizedMpvKey == normalizedKeyCode }) {
      // For the sake of consistency, do not fall through & try to process a key mapping, even
      // if the corresponding menu item is disabled.
      log.verbose("KeyDown: key is a known menu item binding but was not handled. Beeping")
      pwc.keyDown(with: event)
      return
    }

    /// Forward all other key events which the window receives to its controller.
    /// This allows `ESC` & `TAB` key bindings to work, instead of getting swallowed by
    /// MacOS keyboard focus navigation (which PlayerWindow doesn't use).
    if pwc.handleKeyDown(event: event, normalizedMpvKey: normalizedKeyCode) {
      log.trace("KeyDown: was handled by key binding")
      return
    }

    log.trace("KeyDown: did not match any binding")
    /// If we got here, there is no user binding for key, even if an "ignore". Beep to indicate no action.
    /// NOTE: send to PlayerWindowController instead of PlayerWindow!
    /// Otherwise it may get sent to `performKeyEquivalent` multiple times
    pwc.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    guard let pwc else { log.fatalError("No PlayerWindowController for PlayerWindow.keyUp!") }
    keyUpCount += 1
    let keyCode: String = KeyCodeHelper.mpvKeyCode(from: event)

    if processForImmediateView(keyCode: keyCode, pwc) {
      return
    }

    // The user expects certain keys to end editing of text fields. But all the other controls in the sidebar refuse first responder
    // status, so we cannot rely on the key-view-loop to end editing. Need to do this explicitly.
    if let textView = firstResponder as? NSTextView {
      if keyCode == "ENTER" || keyCode == "TAB" {
        self.endEditing(for: textView)
        return
      }
    }

    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)
    log.verbose("KEYUP #\(keyUpCount): \(normalizedKeyCode.quoted)")

    PluginInputManager.handle(
      input: normalizedKeyCode, event: .keyUp, player: pwc.player,
      arguments: pwc.keyEventArgs(event), defaultHandler: {
        // invalid key
        super.keyUp(with: event)
        return true
      })
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let pwc else { log.fatalError("No PlayerWindowController for PlayerWindow.performKeyEquivalent!") }
    let keyCode: String = KeyCodeHelper.mpvKeyCode(from: event)

    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)
    log.verbose("KEY Equiv: \(normalizedKeyCode.quoted)")

    if processForImmediateView(keyCode: keyCode, pwc) {
      return true
    }

    /// AppKit by default will prioritize menu item key equivalents over arrow key navigation
    /// (although for some reason it is the opposite for `ESC`, `TAB`, `ENTER` or `RETURN`).
    /// Need to add an explicit check here for arrow keys to ensure that they always work when desired.
    if let responder = firstResponder, shouldFavorArrowKeyNavigation(for: responder) {
      switch normalizedKeyCode {
      case "UP", "DOWN", "LEFT", "RIGHT":
        // Send arrow keys to view to enable key navigation
        responder.keyDown(with: event)
        return true
      default:
        break
      }
    }
    pwc.updateUI(pullUpdatesFromMpv: true)  // Call explicitly to make sure it gets attention

    if menu?.performKeyEquivalent(with: event) == true {
      log.verbose("KeyEquiv: key was handled by menu item; returning")
      return true
    }

    let staticMenuItemMappings = AppInputConfig.staticMenuItemMappings
    if staticMenuItemMappings.contains(where: { $0.normalizedMpvKey == normalizedKeyCode }) {
      // For the sake of consistency, do not fall through & try to process a key mapping, even
      // if the corresponding menu item is disabled.
      log.verbose("KeyEquiv: key was not handled, but is a known menu item binding. Skipping")
      return false
    }

    /// Need to check this to prevent a strange bug, where using `Ctrl+{key}` will activate a menu item which is mapped as `{key}`.
    /// MacOS quirk? Obscure feature? A user has also demonstrated a case where `Space` is ignored. It looks like bindings which don't
    /// use the command key are sometimes unreliable.
    /// Let's take all the bindings which don't include command and invert their precedence, so that the window is allowed to handle it
    /// before the menu.
    if pwc.handleKeyDown(event: event, normalizedMpvKey: normalizedKeyCode) {
      log.trace("KeyEquiv: trying to process as a key binding")
      return true
    }

    // Apparently it is important to return false here, for some system shortcuts to be handled,
    // e.g. ⌘` (command+grave), which cycles application windows
    log.verbose("KeyEquiv: key is unrecognized")
    return false
  }

  private func processForImmediateView(keyCode: String, _ pwc: PlayerWindowController) -> Bool {
    if keyCode == "ESC" || keyCode == "ENTER" {
      if pwc.isInInteractiveMode, let cropController = pwc.cropSettingsView {
        cropController.handleKeyDown(mpvKeyCode: keyCode)
        return true
      } else if pwc.isInMiniPlayer, pwc.miniPlayer.volumePopover.isShown {
        log.verbose("Hiding miniPlayer volume popover")
        pwc.miniPlayer.hideVolumePopover()
        return true
      }
    }
    return false
  }

  private func shouldFavorArrowKeyNavigation(for responder: NSResponder) -> Bool {
    if responder as? NSTextView != nil {
      // Always favor text fields
      return true
    }
    /// There is some ambiguity about when a table is in focus, so only favor arrow keys when there's
    /// already a selection:
    if let tableView = responder as? NSTableView, !tableView.selectedRowIndexes.isEmpty {
      return true
    }
    return false
  }

  // MARK: - Custom Window fixes

  override var canBecomeKey: Bool {
    if isCustomWindowStyle {
      return true
    }
    return super.canBecomeKey
  }

  override var level: NSWindow.Level {
    didSet {
      // An AppKit bug introduced in MacOS Sequoia causes tracking areas to stop responding after changing window level.
      // Standard workaround for Apple bugs: toggle off and then on again.
      pwc?.updateTrackingAreas()
    }
  }

  override var canBecomeMain: Bool {
    if isCustomWindowStyle {
      return true
    }
    return super.canBecomeMain
  }

  /// Setting `alphaValue=0` for Close & Miniaturize (red & green traffic lights) buttons causes `File` > `Close`
  /// and `Window` > `Minimize` to be disabled as an unwanted side effect. This can cause key bindings to fail
  /// during animations or if we're not careful to set `alphaValue=1` for hidden items. Permanently enabling them
  /// here guarantees consistent behavior.
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    /// Could not find a better way to test for these two. They don't appear to be exposed anywhere.
    /// They are also present in Zoom button's context menu.
    /// `_zoomLeft:` == `Window` > `Move Window to Left Side of Screen`
    /// `_zoomRight:` == `Window` > `Move Window to Right Side of Screen`
    /// `_zoomFill:` added in MacOS Sequoia
    /// `_zoomCenter:` added in MacOS Sequoia
    if let selectorString = item.action?.description {
      if selectorString.starts(with: "_zoom") {
        // Catch-all for above actions. Disallow in full screen:
        return !isFullScreen && !isMusicMode
      }
      /// Also disable `_moveToDisplay:` which is a Sidecar feature:
      if selectorString.starts(with: "_move") {
        return !isFullScreen
      }

      if selectorString.starts(with: "_") {
        // Other internal Apple features such as "Window > Remove Window from Set"
        return super.validateUserInterfaceItem(item)
      }
    }

    switch item.action {
    case #selector(self.performClose(_:)):
      return true
    case #selector(self.performMiniaturize(_:)):
      // Do not allow when in legacy full screen
      return !isFullScreen
    case #selector(self.performZoom(_:)), #selector(self.zoom(_:)):
      /// `zoom:` is an item in the Zoom button (green traffic light)'s context menu.
      /// `performZoom:` is the equivalent item in the `Window` menu
      return !isFullScreen && !isMusicMode
    default:
      // See if PlayerWindowController recognizes it and can respond
      if let pwc, let pwcResponse = pwc.validateUserInterfaceItem(item) {
        return pwcResponse
      }
      // See if super can handle it
      let response = super.validateUserInterfaceItem(item)
      return response
    }
  }

  /// See `validateUserInterfaceItem()`.
  override func performClose(_ sender: Any?) {
    self.close()
  }

  /// Need to override this for Minimize to work when `!styleMask.contains(.titled)`
  override func performMiniaturize(_ sender: Any?) {
    self.miniaturize(self)
  }

  /// See `windowShouldZoom`, `windowWillUseStandardFrame` in `PlayerWindowController` for zoom handling.
  override func zoom(_ sender: Any?) {
    super.zoom(sender)
  }
  
}

