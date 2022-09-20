//
//  AppInputBindingController.swift
//  iina
//
//  Created by Matt Svoboda on 9/18/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

// Helps keep track of, and helps make dynamic updates to, the key bindings in
// the Plugin menu.
class PluginMenuKeyBindingMediator {
  class Entry {
    let rawKey: String
    let pluginName: String
    let menuItem: NSMenuItem

    init(rawKey: String, pluginName: String, _ menuItem: NSMenuItem) {
      self.rawKey = rawKey
      self.pluginName = pluginName
      self.menuItem = menuItem
    }
  }

  fileprivate var entryList: [Entry] = []
  // Arg0 = failureList
  fileprivate var didComplete: ([Entry]) -> Void

  init(completionHandler: @escaping ([Entry]) -> Void) {
    self.didComplete = completionHandler
  }

  func add(rawKey: String, pluginName: String, _ menuItem: NSMenuItem) {
    entryList.append(Entry(rawKey: rawKey, pluginName: pluginName, menuItem))
  }
}

class AppActiveBindingController {

  static private func makeDefaultSection(from bindingList: [KeyMapping] = []) -> MPVInputSection {
    return MPVInputSection(name: MPVInputSection.DEFAULT_SECTION_NAME, bindingList, isForce: true)
  }

  // This exists so that new instances of PlayerBindingController can immediately populate their default section.
  // Try not to use it anywhere else, as we already have a lot of redundant binding info scattered around.
  private var currentDefaultSection: MPVInputSection = makeDefaultSection()

  // Each player can have a set of plugins associated with it, and each can place keyboard shortcuts in the menubar.
  // But there is only a single menubar, while Plugin menu items will change each time a different player window comes into focus.
  // Also, each time the player bindings are changed, they may override some of the menu items, so the Plugin menu will need to be
  // updated to stay consistent. This object will facilitate those updates.
  private var pluginMenuMediator: PluginMenuKeyBindingMediator? = nil

  // Cached bindings for each type
  private var currentDefaultSectionBindings: [ActiveBindingMeta] = []
  private var currentPluginMenuBindings: [ActiveBindingMeta] = []

  // The end product of this class
  var currentActiveBindingsList: [ActiveBindingMeta] {
    get {
      currentPluginMenuBindings + currentDefaultSectionBindings
    }
  }

  // The 'default' section contains the bindings loaded from the currently
  // selected input config file, and will be shared for all `PlayerCore` instances.
  // This method also calculates which of these will qualify as menu item bindings.
  func replaceDefaultSectionBindings(_ bindingList: [KeyMapping]) -> [ActiveBindingMeta] {
    Logger.log("Rebuilding 'default' section bindings (\(bindingList.count) lines)")
    // Build meta to return. These two variables form a quick & dirty SortedDictionary:
    var defaultSectionMetaList: [ActiveBindingMeta] = []
    var defaultSectionMetaDict: [Int: ActiveBindingMeta] = [:]

    // If multiple bindings map to the same key, choose the last one
    var enabledBindingsDict: [String: KeyMapping] = [:]
    var orderedKeyList: [String] = []
    for binding in bindingList {
      guard let bindingID = binding.bindingID else {
        Logger.fatal("setDefaultSectionBindings(): is missing bindingID: \(binding)")
      }
      let key = binding.normalizedMpvKey
      // Derive the binding's metadata and determine whether it should be enabled (in which case meta.isEnabled will be set to `true`).
      // Note: this mey also put a different object into `meta.binding`, so from here on `meta.binding`
      // should be used instead of `binding`.
      let meta = analyzeDefaultSectionBinding(binding)
      defaultSectionMetaList.append(meta)
      defaultSectionMetaDict[bindingID] = meta

      if meta.isEnabled {
        if enabledBindingsDict[key] == nil {
          orderedKeyList.append(key)
        } else {
          if let bindingID = enabledBindingsDict[key]?.bindingID,
             let overriddenMeta = defaultSectionMetaDict[bindingID] {
            overriddenMeta.isEnabled = false
            overriddenMeta.statusMessage = "This binding was overridden by another binding below it which has the same key"
          }
        }
        // Store it, overwriting any previous entry:
        enabledBindingsDict[key] = meta.binding
      }
    }

    // This will also update the isMenuItem status of each
    (NSApp.delegate as? AppDelegate)?.menuController.updateKeyEquivalentsFrom(defaultSectionMetaList)

    // Send bindings to all players: they will need to re-determine which bindings they want to override.
    let enabledBindingList = defaultSectionMetaList.filter { $0.isEnabled }.map { $0.binding }

    // FIXME: add a lock around this (1/2)
    self.currentDefaultSection = AppActiveBindingController.makeDefaultSection(from: enabledBindingList)  // cache it so that new players can use it
    // One of these will set `currentPluginMenuBindings`
    for player in PlayerCore.playerCores {
      player.inputController.refreshDefaultSectionBindings()
    }

    currentDefaultSectionBindings = defaultSectionMetaList

    return currentActiveBindingsList
  }

  private func analyzeDefaultSectionBinding(_ binding: KeyMapping) -> ActiveBindingMeta {

    let meta = ActiveBindingMeta(binding, origin: .confFile, srcSectionName: MPVInputSection.DEFAULT_SECTION_NAME, isMenuItem: false, isEnabled: false)

    if binding.rawKey == "default-bindings" && binding.action.count == 1 && binding.action[0] == "start" {
      Logger.log("Skipping line: \"default-bindings start\"", level: .verbose)
      meta.statusMessage = "IINA does not use default-level (\"weak\") bindings"
      return meta
    }

    // Special case: do bindings specify a different section using curly braces?
    if let destinationSectionName = binding.destinationSection {
      if destinationSectionName == MPVInputSection.DEFAULT_SECTION_NAME {
        // Drop "{default}" because it is unnecessary and will get in the way of libmpv command execution
        let newRawAction = Array(binding.action.dropFirst()).joined(separator: " ")
        meta.binding = KeyMapping(rawKey: binding.rawKey, rawAction: newRawAction, isIINACommand: binding.isIINACommand, comment: binding.comment)
      } else {
        Logger.log("Skipping binding which specifies section \"\(destinationSectionName)\": \(binding.rawKey)", level: .verbose)
        meta.statusMessage = "Adding to input sections other than \"\(MPVInputSection.DEFAULT_SECTION_NAME)\" are not supported"
        return meta
      }
    }
    meta.isEnabled = true
    return meta
  }

  func getCurrentDefaultSection() -> MPVInputSection {
    // FIXME: add a lock to this (2/2)
    return currentDefaultSection
  }

  func setPluginMenuMediator(_ mediator: PluginMenuKeyBindingMediator?) {
    pluginMenuMediator = mediator
    if let mediator = mediator {
      Logger.log("Plugin menu updated, requests \(mediator.entryList.count) key bindings", level: .verbose)
    }
    // This will call `updatePluginMenuBindings()`
    PlayerCore.active.inputController.rebuildCurrentActiveBindingList()
  }

  // Each plugin's bindings are equivalent to a "weak" input section.
  func updatePluginMenuBindings(_ bindingsDict: inout [String: ActiveBindingMeta]) {
    var pluginMenuBindings: [ActiveBindingMeta] = []

    if let mediator = self.pluginMenuMediator {
      var failureList: [PluginMenuKeyBindingMediator.Entry] = []
      for entry in mediator.entryList {
        let mpvKey = KeyCodeHelper.normalizeMpv(entry.rawKey)

        // Kludge here: storing plugin name info in the action field, then making sure we don't try to execute it
        let action = "Plugin > \(entry.pluginName) > \(entry.menuItem.title)"
        let binding = KeyMapping(rawKey: entry.rawKey, rawAction: action, isIINACommand: true)
        let bindingMeta = ActiveBindingMeta(binding, origin: .iinaPlugin, srcSectionName: entry.pluginName, isMenuItem: true, isEnabled: false)

        if let existingBindingMeta = bindingsDict[mpvKey], !existingBindingMeta.binding.isIgnored {
          // Conflict! Key binding already reserved
          failureList.append(entry)
          entry.menuItem.keyEquivalent = ""
          entry.menuItem.keyEquivalentModifierMask = []
        } else {
          if let (kEqv, kMdf) = KeyCodeHelper.macOSKeyEquivalent(from: mpvKey) {
            entry.menuItem.keyEquivalent = kEqv
            entry.menuItem.keyEquivalentModifierMask = kMdf

            bindingsDict[mpvKey] = bindingMeta
            bindingMeta.isEnabled = true
          }
        }

        pluginMenuBindings.append(bindingMeta)
      }

      mediator.didComplete(failureList)
    }

    currentPluginMenuBindings = pluginMenuBindings
    Logger.log("Updated Plugin menu bindings (count: \(currentPluginMenuBindings.count))")

    sendActiveBindingsChangedNotification()
  }

  func sendActiveBindingsChangedNotification() {
    NotificationCenter.default.post(Notification(name: .iinaAppActiveKeyBindingsChanged, object: currentActiveBindingsList))
  }

}
