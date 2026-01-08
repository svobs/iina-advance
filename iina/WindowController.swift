//
//  WindowController.swift
//  iina
//
//  Created by Matt Svoboda on 2025-02-08.
//  Copyright © 2025 lhc. All rights reserved.
//


/// All window controllers in the app are expected to inherit from this class.
class WindowController: NSWindowController {

  var isOpen: Bool {
    guard let window else { return false }
    /// Also check if hidden due to PIP, or minimized.
    /// NOTE: `window.isVisible` returns `false` if the window is ordered out, which we do sometimes,
    /// as well as in the minimized or hidden states.
    /// Check against our internally tracked window state lists also:
    let savedStateName = window.savedStateName
    let isVisible = window.isVisible || UIState.shared.windowsOpen.contains(savedStateName)
    let isMinimized = UIState.shared.windowsMinimized.contains(savedStateName)
    return isVisible || isMinimized
  }

  var mouseLocationInWindow: NSPoint {
    return window!.convertPoint(fromScreen: NSEvent.mouseLocation)
  }

  var isLeftMouseButtonDown: Bool {
    (NSEvent.pressedMouseButtons & (1 << 0)) != 0
  }

  func openWindow(_ sender: Any?) {
    if !AppDelegate.shared.isInteractiveLaunch {
      guard AppDelegate.shared.isDoneLaunching else {
        Logger.log.verbose("Aborting openWindow (\(window?.savedStateName ?? "nil")): non-interactive launch is still starting")
        return
      }

      // FIXME: unclear if this works or is even reachable. Maybe launches should stay non-interactive?
      Logger.log.verbose("OpenWindow (\(window?.savedStateName ?? "nil")) requested for non-interactive launch; will make interactive")
      AppDelegate.shared.ensureInteractiveLaunchEnabled()
    }
    guard let window else {
      Logger.log.error("Cannot open window: no window object!")
      return
    }
    assert(window.windowController as? PlayerWindowController == nil,
           "WindowController.openWindow should be overriden for player windows!")

    refreshWindowOpenCloseAnimation()

    let windowName = window.savedStateName
    if !Preference.bool(for: .isRestoreInProgress), !windowName.isEmpty {
      /// Make sure `windowsOpen` is updated. This patches certain possible race conditions during launch
      UIState.shared.windowsOpen.insert(windowName)
    }

    postWindowIsReadyToShow()
  }

  /// Changes opening & closing animations of window based on app lifecycle state & other variables
  ///
  /// See also: `UIState.shared.windowOpenCloseAnimations`.
  func refreshWindowOpenCloseAnimation() {
    assert(DispatchQueue.isExecutingIn(.main))

    guard let window, window.savedStateName != "" else {
      Logger.log.verbose("WindowOpenCloseAnimation: empty savedStateName for window; skipping")
      return
    }

    let savedStateName = window.savedStateName
    guard IINAAnimation.isAnimationEnabled else {
      Logger.log.verbose("WindowOpenCloseAnimation: animation disabled or motion reduction enabled; using .none for \(savedStateName.quoted)")
      window.animationBehavior = .none
      return
    }

    guard !AppDelegate.shared.isTerminating else {
      // Just terminate ASAP
      Logger.log.verbose("WindowOpenCloseAnimation: app is terminating; using .none for \(savedStateName.quoted)")
      window.animationBehavior = .none
      return
    }

    guard var autosaveEnum = WindowAutosaveName(savedStateName) else {
      assert(false, "Expected guaranteed match for savedStateName \(savedStateName)")
      Logger.log.error("WindowOpenCloseAnimation: no match for savedStateName \(savedStateName). Skipping")
      return
    }

    let animationType: Preference.WindowOpenCloseAnimation

    if !AppDelegate.shared.isDoneLaunching || (autosaveEnum == .welcome && AppDelegate.shared.initialWindow.isFirstLoad) {
      // Use zoom effect for initial open
      animationType = Preference.enum(for: .windowLaunchAnimation)

      if animationType == .useDefault {
        window.animationBehavior = .documentWindow
        return
      }

    } else if autosaveEnum.isPlayerWindow {
      animationType = Preference.enum(for: .playerWindowOpenCloseAnimation)
    } else {
      animationType = Preference.enum(for: .auxWindowOpenCloseAnimation)
    }

    let behavior: NSWindow.AnimationBehavior
    switch animationType {
    case .zoomIn:
      behavior = .documentWindow
    case .none:
      behavior = .default
    case .useDefault:
      if autosaveEnum.isPlayerWindow {
        // a little kludgey, but makes the matching logic work for the array below
        autosaveEnum = .anyPlayerWindow
      }

      guard let behaviorFound = UIState.shared.windowOpenCloseAnimations[autosaveEnum] else {
        assert(false, "Expected guaranteed match for WindowAutosaveName \(autosaveEnum)")
        Logger.log.error("WindowOpenCloseAnimation: no match for WindowAutosaveName \(autosaveEnum); skipping")
        return
      }
      behavior = behaviorFound
    }

    Logger.log.verbose("WindowOpenCloseAnimation: setting behavior for \(savedStateName) to \(behavior.rawValue)")
    window.animationBehavior = behavior
  }

  func postWindowIsReadyToShow() {
    NotificationCenter.default.post(Notification(name: .windowIsReadyToShow, object: window))
  }

  func postWindowMustCancelShow() {
    NotificationCenter.default.post(Notification(name: .windowMustCancelShow, object: window))
  }

}
