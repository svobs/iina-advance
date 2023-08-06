//
//  PlayerCoreStore.swift
//  iina
//
//  Created by Matt Svoboda on 8/4/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class PlayerCoreStore {
  private let lock = Lock()
  private var playerCoreCounter = 0

  private var playerCores: [PlayerCore] = []

  weak var lastActive: PlayerCore?

  // Returns a copy of the list of PlayerCores, to ensure concurrency
  func getPlayerCores() -> [PlayerCore] {
    var coreList: [PlayerCore]? = nil
    lock.withLock {
      coreList = playerCores
    }
    return coreList!
  }

  func _getOrCreateFirst() -> PlayerCore {
    var core: PlayerCore
    if playerCores.isEmpty {
      core = _createNewPlayerCore()
    } else {
      core = playerCores[0]
    }
    return core
  }

  func getOrCreateFirst() -> PlayerCore {
    var core: PlayerCore? = nil
    lock.withLock {
      core = _getOrCreateFirst()
    }
    core!.start()
    return core!
  }

  func getActiveOrCreateNew() -> PlayerCore {
    var core: PlayerCore? = nil
    lock.withLock {
      if playerCores.isEmpty {
        core = _createNewPlayerCore()
      } else {
        if Preference.bool(for: .alwaysOpenInNewWindow) {
          core = _getIdleOrCreateNew()
        } else {
          core = getActive()
        }
      }
    }
    core!.start()
    return core!
  }

  func getNonIdle() -> [PlayerCore] {
    var cores: [PlayerCore]? = nil
    lock.withLock {
      cores = playerCores.filter { !$0.info.isIdle }
    }
    return cores!
  }

  func _getIdleOrCreateNew() -> PlayerCore {
    var core: PlayerCore
    if let idleCore = playerCores.first(where: { $0.info.isIdle && !$0.info.fileLoading }) {
      core = idleCore
    } else {
      core = _createNewPlayerCore()
    }
    return core
  }

  func getIdleOrCreateNew() -> PlayerCore {
    var core: PlayerCore? = nil
    lock.withLock {
      core = _getIdleOrCreateNew()
    }
    return core!
  }

  func getActive() -> PlayerCore {
    if let wc = NSApp.mainWindow?.windowController as? MainWindowController {
      return wc.player
    } else {
      return getOrCreateFirst()
    }
  }

  private func _playerExists(withLabel label: String) -> Bool {
    var exists = false
    exists = playerCores.first(where: { $0.label == label }) != nil
    return exists
  }

  private func _createNewPlayerCore(withLabel label: String? = nil) -> PlayerCore {
    Logger.log("Creating playerCore \(label ?? "(no label)")")
    let pc: PlayerCore
    if let label = label {
      if _playerExists(withLabel: label) {
        Logger.fatal("Cannot create new PlayerCore: a player already exists with label \(label.quoted)")
      }
      pc = PlayerCore(label)
    } else {
      while _playerExists(withLabel: "\(playerCoreCounter)") {
        playerCoreCounter += 1
      }
      pc = PlayerCore("\(playerCoreCounter)")
      playerCoreCounter += 1
    }
    Logger.log("Successfully created PlayerCore \(pc.label)")

    playerCores.append(pc)
    return pc
  }

  func createNewPlayerCore(withLabel label: String? = nil, start: Bool = true) -> PlayerCore {
    var pc: PlayerCore? = nil
    lock.withLock {
      pc = _createNewPlayerCore(withLabel: label)
    }
    if start {
      pc!.start()
    }
    return pc!
  }

  func findIdlePlayerCore() -> PlayerCore? {
    var idleCore: PlayerCore?
    lock.withLock {
      idleCore = playerCores.first { $0.info.isIdle && !$0.info.fileLoading }
    }
    return idleCore
  }

}
