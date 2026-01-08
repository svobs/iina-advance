//
//  PWin_Enums.swift
//  iina
//
//  Created by Matt Svoboda on 2024-10-08.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation


/// Each `PlayerWindow` has a session associated with it. The session's state can be saved using `PlayerSaveState`.
/// This class helps keep track of the lifecycle state of the session.
enum PWinSessionState: Sendable, CustomStringConvertible {

  /// No current or previous session
  case noSession

  /// Closed window which may still contain state from a previously open session
  case closedSession

  /// Restoring the session from prior launch.
  /// `playerState`: contains state data needed to restore the UI state from a previous launch, loaded from prefs.
  case restoring(playerState: PlayerSaveState)

  /// Like `.restoring`, this state can only exist for players created at launch.
  /// Indicates that the player may have CLI options loaded (is really only needed to avoid `resetOptionsForNewSession()`)
  case creatingCLI

  /// Opening window (or reopening closed window) for new session & new file.
  case creatingNew

  /// Reusing an already open window, and discarding its current session, for new session & new file.
  case newReplacingOpen

  /// Reusing a previously closed window, and discarding its previous session, for new session & new file.
  case newReplacingClosed

  /// Existing window & session, but new file (i.e. current media is changing via playlist navigation).
  /// See also: `isChangingVideoTrack`.
  case existingSession_startingNewPlayback

  /// Existing window, session, & file, but current video track was changed.
  case existingSession_videoTrackChangedForSamePlayback

  /// Existing window, session, file.
  case existingSession_continuing

  /// Need to specify this so that `playerState` is not included...
  var description: String {
    switch self {
    case .noSession:
      "noSession"
    case .closedSession:
      "closedSession"
    case .restoring:
      "restoring"
    case .creatingCLI:
      "creatingCLI"
    case .creatingNew:
      "creatingNew"
    case .newReplacingOpen:
      "newReplacingOpen"
    case .newReplacingClosed:
      "newReplacingClosed"
    case .existingSession_startingNewPlayback:
      "existingSession_startingNewPlayback"
    case .existingSession_videoTrackChangedForSamePlayback:
      "existingSession_videoTrackChangedForSamePlayback"
    case .existingSession_continuing:
      "existingSession_continuing"
    }
  }

  /// Changes to a new state based on the current state, assuming the action is to create a new session.
  func newSession() -> PWinSessionState {
    switch self {
    case .existingSession_continuing:
      return .newReplacingOpen
    case .noSession:
      return .creatingNew
    case .closedSession:
      return .newReplacingClosed
    default:
      Logger.fatal("Unexpected sessionState for newSession(): \(self)")
    }
  }

  /// Is `true` only while restore from previous launch is still in progress; `false` otherwise.
  var isRestoring: Bool {
    if case .restoring = self {
      return true
    }
    return false
  }

  /// Returns `true` if session finished its initial load. May be changing tracks or files within the session.
  var hasOpenSession: Bool {
    return !isNone && !isStartingNewPlaybackManually
  }

  /// Returns true if starting or resuming a session.
  var isStartingSession: Bool {
    return isStartingNewPlaybackManually
  }

  /// Returns true if starting a new session, i.e., same as `isStartingSession()` but excluding `restoring`
  var isStartingNewSession: Bool {
    if case .restoring = self {
      return false
    }
    return isStartingNewPlaybackManually
  }

  /// Most similar to the term "Opening file" in Settings window's UI, but also applies when changing video track
  /// in the same file.
  ///
  /// Note that case `.restoring` is considered to be opening a file and thus returns `true`.
  /// See also: `isStartingNewPlaybackManually`.
  var isChangingVideoTrack: Bool {
    switch self {
    case .restoring,
        .creatingNew,
        .creatingCLI,
        .newReplacingOpen,
        .newReplacingClosed,
        .existingSession_startingNewPlayback,
        .existingSession_videoTrackChangedForSamePlayback:
      return true
    case .existingSession_continuing,
        .noSession,
        .closedSession:
      return false
    }
  }

  /// AKA "opening file" when using the same language as Settings window.
  var isStartingNewPlayback: Bool {
    switch self {
    case .restoring,
        .creatingNew,
        .creatingCLI,
        .newReplacingOpen,
        .newReplacingClosed,
        .existingSession_startingNewPlayback:
      return true
    case .existingSession_videoTrackChangedForSamePlayback,
        .existingSession_continuing,
        .noSession,
        .closedSession:
      return false
    }
  }

  /// Most similar to the term "Opening file manually" in Settings window's UI.
  ///
  /// Note that case `.restoring` is considered to be opening a file and thus returns `true`.
  var isStartingNewPlaybackManually: Bool {
    switch self {
    case .restoring,
        .creatingNew,
        .creatingCLI,
        .newReplacingOpen,
        .newReplacingClosed:
      return true
    case .existingSession_startingNewPlayback,
        .existingSession_videoTrackChangedForSamePlayback,
        .existingSession_continuing,
        .noSession,
        .closedSession:
      return false
    }
  }

  var isNone: Bool {
    switch self {
      case .noSession,
        .closedSession:
      return true
    default:
      return false
    }
  }
}


extension PlayerWindowController {
  enum TrackingArea: Int {
    static let key: String = "area"

    case playerWindow = 0
    case playSlider
    case volumeSlider
  }

  enum CursorType {
    case normalCursor
    case resized_AtLeftMin
    case resized_AtRightMax
    case resizing_BothDirections
    case hoveringInSlider
  }

  /// Animation state. Used for fadeable views, OSD.
  enum UIAnimationState {
    case shown, hidden, willShow, willHide

    var isInTransition: Bool {
      return self == .willShow || self == .willHide
    }
  }

}  // extension PlayerWindowController


/// Enumeration representing the status of the [mpv](https://mpv.io/manual/stable/) A-B loop command.
///
/// The A-B loop command cycles mpv through these states:
/// - Cleared (looping disabled)
/// - A loop point set
/// - B loop point set (looping enabled)
enum LoopStatus: Int {
  case cleared = 0
  case aSet
  case bSet
}


enum PlayerWindowMode: Int, CustomStringConvertible {
  /// Note: both `windowed` & `windowedInteractive` modes are considered windowed"
  case windowedNormal = 1
  case fullScreenNormal
  case musicMode
  case windowedInteractive
  case fullScreenInteractive

  var description: String {
    switch self {
    case .windowedNormal: return "windowedNormal(\(rawValue))"
    case .fullScreenNormal: return "fullScreenNormal(\(rawValue))"
    case .musicMode: return "musicMode(\(rawValue))"
    case .windowedInteractive: return "windowedInteractive(\(rawValue))"
    case .fullScreenInteractive: return "fullScreenInteractive(\(rawValue))"
    }
  }

  var alwaysLockViewportToVideoSize: Bool {
    switch self {
    case .musicMode:
      return true
    case .fullScreenNormal, .windowedNormal, .windowedInteractive, .fullScreenInteractive:
      return false
    }
  }

  var neverLockViewportToVideoSize: Bool {
    switch self {
    case .fullScreenNormal:
      return true
    case .musicMode, .windowedInteractive, .fullScreenInteractive, .windowedNormal:
      return false
    }
  }

  var isWindowed: Bool {
    return self == .windowedNormal || self == .windowedInteractive
  }

  var isFullScreen: Bool {
    return self == .fullScreenNormal || self == .fullScreenInteractive
  }

  var isInteractiveMode: Bool {
    return self == .windowedInteractive || self == .fullScreenInteractive
  }

  var lockViewportToVideoSize: Bool {
    if alwaysLockViewportToVideoSize {
      return true
    }
    if neverLockViewportToVideoSize {
      return false
    }
    return Preference.bool(for: .lockViewportToVideoSize)
  }

  var canShowSidebars: Bool {
    return self == .windowedNormal || self == .fullScreenNormal
  }

  var mustShowCursorAlways: Bool {
    switch self {
    case .windowedNormal, .fullScreenNormal:
      return false
    case .musicMode, .windowedInteractive, .fullScreenInteractive:
      return true
    }
  }

  /// If `true`: tell mpv to show black bars around video if necessary.
  /// If `false`: tell mpv to stretch or shrink video to size of window.
  var needsMpvKeepaspectWindow: Bool {
    switch self {
    case .fullScreenNormal:
      return true
    case .windowedNormal:
      let keepAspect = !Preference.bool(for: .lockViewportToVideoSize)
      return keepAspect
    case .windowedInteractive, .fullScreenInteractive, .musicMode:
      return false
    }
  }
}


/// Represents a visibility mode for a given component in the player window.
/// See: `FadeableViewsHandler`, `LayoutState`.
enum VisibilityMode {
  case hidden
  case showAlways
  case showFadeableTopBar     // fade in as part of the top bar
  case showFadeableNonTopBar  // fade in as a fadeable view which is not top bar

  var isShowable: Bool {
    return self != .hidden
  }

  var isFadeable: Bool {
    switch self {
    case .showFadeableTopBar, .showFadeableNonTopBar:
      return true
    default:
      return false
    }
  }
}


enum InteractiveMode: Int {
  case crop = 1
  case freeSelecting

  @MainActor
  func viewController() -> CropBoxViewController {
    var vc: CropBoxViewController
    switch self {
    case .crop:
      vc = CropSettingsViewController()
    case .freeSelecting:
      vc = FreeSelectingViewController()
    }
    return vc
  }
}

/// Used within a `PWinGeometry` to indicate how a given player window must fit inside its given screen.
enum ScreenFit: Int {

  case noConstraints = 0

  /// Constrains inside `screen.visibleFrame`. Windowed modes only.
  case stayInside

  /// Constrains and centers inside `screen.visibleFrame`. Windowed modes only.
  case centerInside

  /// Constrains inside `screen.frame`
  case legacyFullScreen

  /// Constrains inside `screen.frameWithoutCameraHousing`. Provided here for completeness, but not used at present.
  case nativeFullScreen

  static let musicMode: ScreenFit = .stayInside

  var isFullScreen: Bool {
    switch self {
    case .legacyFullScreen, .nativeFullScreen:
      return true
    default:
      return false
    }
  }

  var shouldMoveWindowToKeepInContainer: Bool {
    switch self {
    case .legacyFullScreen, .nativeFullScreen:
      return true
    case .stayInside, .centerInside:
      return Preference.bool(for: .moveWindowIntoVisibleScreenOnResize)
    default:
      return false
    }
  }

  func changeDesiredFit(to desiredFit: ScreenFit? = nil) -> ScreenFit {
    if self.isFullScreen {
      // If already in full screen, it makes no sense to update screenFit, so just ignore the requested change
      return self
    }
    if let desiredFit {
      return desiredFit
    } else {
      // do not center in screen again unless explicitly requested
      return self == .centerInside ? .stayInside : self
    }
  }
}

/// Used within a `PWinGeometry` to indicate how to configure `videoView`, `viewportView`, and the spacers between them.
enum TransitionCategory: Int {
  /// Normal = not animating. Viewport & its subiews should follow their usual rules based on other `PWinGeometry` state vars.
  case none = 0

  /// All other transition animations which does not need a special case / special handling.
  case general

  // - Special Cases
  
  case openingViewportInMusicMode
  case closingViewportInMusicMode
  case enteringMusicMode
  case exitingMusicMode

  case enteringInteractiveMode
  case cropBeforeExitingInteractiveMode
  case exitingInteractiveMode

  case enteringPIP

}
