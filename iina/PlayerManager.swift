//
//  PlayerManager.swift
//  iina
//
//  Created by Matt Svoboda on 8/4/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

@MainActor
final class PlayerManager {
  static let shared = PlayerManager()

  private var playerCoreCounter = 0

  var playerCores: [PlayerCore] = []

  /// Audio-only player. Needed for listing audio devices when no player windows are open.
  /// Should not be used for playing anything.
  var demoPlayer: PlayerCore? = nil

  var pipPlayer: PlayerCore? = nil {
    willSet {
      let usurperPlayer = newValue
      if let prevPlayer = pipPlayer, prevPlayer != usurperPlayer, let prevPWC = prevPlayer.pwc, prevPWC.currentLayout.isInPiP {
        prevPWC.animationPipeline.submit(.instantTask {
          prevPlayer.log.debug("PlayerManager: another player wants PiP; exiting PiP")
          prevPWC.exitPIP()
        })
      }
    }
  }

  /// Returns the last player whose window was "active" (or in MacOS terminology, was the key window).
  var lastActivePlayer: PlayerCore? {
    get {
      return _lastActivePlayer ?? findCurrentlyActivePlayer()
    }
    set {
      _lastActivePlayer = newValue
    }
  }
  weak private var _lastActivePlayer: PlayerCore?

  var allPlayersShutdown: Bool {
    let runningLabels = playerCores.compactMap({ player in
      // Non-interactive players don't have callbacks registered.
      // So just assume they finished shutting down and hope it's fine.
      !player.isInteractivePlayer || player.isShutDown ? nil : player.label}
    )
    if !runningLabels.isEmpty {
      Logger.log.verbose("Players have not yet shut down: \(runningLabels)")
      return false
    }
    return true
  }

  private func _getOrCreateFirst() -> PlayerCore {
    if playerCores.isEmpty {
      return createNewPlayerCore()
    }
    return playerCores[0]
  }

  func getOrCreateFirst() -> PlayerCore {
    _getOrCreateFirst()
  }

  func getActiveOrCreateNew() -> PlayerCore {
    if playerCores.isEmpty {
      return createNewPlayerCore()
    } else {
      if Preference.bool(for: .alwaysOpenInNewWindow) {
        return getIdleOrCreateNew()
      } else {
        if let activePlayer = findCurrentlyActivePlayer() {
          return activePlayer
        } else {
          Logger.log.debug("No active player found; creating new")
          return createNewPlayerCore()
        }
      }
    }
  }

  /// `inverseOpenInNewWindowPref` means to negate the current value of pref `.alwaysOpenInNewWindow`
  func getActiveOrNewForMenuAction(inverseOpenInNewWindowPref: Bool) -> PlayerCore {
    let useNew = Preference.bool(for: .alwaysOpenInNewWindow) != inverseOpenInNewWindowPref
    if !useNew, let activePlayer {
      return activePlayer
    }
    // If no active player, need to create new. Or if by pref
    return getIdleOrCreateNew()
  }

  /// Finds a player core which was already created but is not in use (idle or not started), or nil if none
  private func findIdlePlayerCore() -> PlayerCore? {
    var firstIdlePlayer: PlayerCore? = nil
    for p in playerCores {
      let isPlayerIdleOrUnused = p.isIdleOrUnused
      Logger.log.verbose("Player-\(p.label): hasPlayback=\(p.hasPlayback.yn) idle=\((p.state == .idle).yn) → UNUSED=\(isPlayerIdleOrUnused.yesno)")
      if firstIdlePlayer == nil && isPlayerIdleOrUnused {
        firstIdlePlayer = p
      }
    }
    return firstIdlePlayer
  }

  func getNonIdle() -> [PlayerCore] {
    playerCores.filter { $0.isActive && ($0.state != .idle) }
  }

  func getIdleOrCreateNew(loadAdditionalMpvOptionsFromPrefs: Bool = true) -> PlayerCore {
    if let idleCore = findIdlePlayerCore() {
      Logger.log.debug("Found idle player: #\(idleCore.label)")
      return idleCore
    }
    Logger.log.debug("No idle player found; creating new")
    return createNewPlayerCore()
  }

  /// - Important: Code referencing this property **must** be run on the main thread because it references
  ///   [NSApplication.pwc](https://developer.apple.com/documentation/appkit/nsapplication/1428723-mainwindow)
  var activePlayer: PlayerCore? {
    findCurrentlyActivePlayer()
  }

  /// The "active" player is the player attached to the current key window, if any.
  /// If no player window is the key window, returns `nil`.
  private func findCurrentlyActivePlayer() -> PlayerCore? {
    if let wc = NSApp.keyWindow?.windowController as? PlayerWindowController, wc.player.isActive {
      return wc.player
    } else {
      return nil
    }
  }

  /// Demo player is a redundant player which is used for app-wide things such as configuring audio devices or input bindings in prefs
  func getOrCreateDemo() -> PlayerCore {
    let player: PlayerCore
    if let demoPlayer {
      player = demoPlayer
    } else {
      Logger.log.debug("Creating demo player")
      player = PlayerCore.buildDemoPlayer()
      demoPlayer = player
    }
    player.startPlayer()
    return player
  }

  private func playerExists(withLabel label: String) -> Bool {
    return playerCores.first(where: { $0.label == label }) != nil
  }

  /// ALways use this to create a new player.
  /// This always starts the given player after creating it.
  func createNewPlayerCore(withLabel priorLabel: String? = nil,
                           restoringFrom priorState: PlayerSaveState? = nil,
                           applyingCLI cli: CommandLineState? = nil) -> PlayerCore {
    let player: PlayerCore
    if let priorLabel, let priorState {
      assert(cli == nil, "Cannot restore a PlayerCore while also applying a CLI configuration!")
      // Restoring a saved PlayerCore. We expect these to have a unique ID/label because
      // it incorporates the launchID of a previous launch, and should never conflict with any players created
      // by other launches or this launch.
      Logger.log.debug("Restoring PlayerCore instance with ID \(priorLabel.quoted)")
      guard !playerExists(withLabel: priorLabel) else {
        Logger.fatal("Cannot create new PlayerCore: a player already exists with label \(priorLabel.quoted)")
      }
      player = PlayerCore(priorLabel, restoringFrom: priorState)
    } else {
      // Creating a new PlayerCore for this launch. Need to make sure we give it a unique ID.
      // Each Player ID incorporates this launchID & `playerCoreCounter` starting from 0.
      let playerLabel = UIState.shared.label(forPlayerCore: playerCoreCounter)
      while playerExists(withLabel: playerLabel) {
        playerCoreCounter += 1
      }
      var userOptions: [MPVOptPair] = []
      if let cli {
        // Need to apply CLI options after user's "additional options". So load everything here instead of at window open:
        userOptions.append(contentsOf: PlayerCore.getMpvAdditionalOptionsFromPrefs(Logger.log))
        userOptions.append(contentsOf: cli.mpvArguments)
      }
      Logger.log.debug("Creating new PlayerCore instance with ID=\(playerLabel.quoted) & \(userOptions.count) user options")
      player = PlayerCore(playerLabel, userOptions: userOptions)
      playerCoreCounter += 1

      if let cli {
        // Mark this as a special CLI state so the CLI userOptions don't get overwritten when window opens:
        player.pwc.sessionState = .creatingCLI

        if cli.needsShufflePlaylist {
          // Special handling for this one
          player.log.debug("Found \"shuffle\" request in command-line args. Adding mpv hook to shuffle playlist")
          player.addShufflePlaylistHook()
        }
      }
    }
    Logger.log.debug("Successfully created PlayerCore \(player.label)")

    playerCores.append(player)

    player.startPlayer()
    return player
  }

  func removePlayer(withLabel label: String) {
    playerCores.removeAll(where: { (player) in player.label == label })
    Logger.log.debug("Removed player from app-wide list: \(label.quoted); \(playerCores.count) remain")
  }
}
