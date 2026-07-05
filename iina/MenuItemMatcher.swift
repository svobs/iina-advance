//
//  MenuItemMatcher.swift
//  iina
//
//  Created by Matt Svoboda on 2025-12-25.
//  Copyright © 2025 lhc. All rights reserved.
//

extension MenuController {
  struct BindableMenuItem {
    let menuItem: NSMenuItem
    let iinaCmd: Bool
    let actionForMenuItem: [String]
    let normalizeLastNum: Bool
    let numRange: ClosedRange<Double>?
    let l10nKey: String?

    init(_ menuItem: NSMenuItem, iinaCmd: Bool, _ actionForMenuItem: [String], normalizeLastNum: Bool = false,
         _ numRange: ClosedRange<Double>? = nil, l10nKey: String? = nil) {
      self.menuItem = menuItem
      self.iinaCmd = iinaCmd
      self.actionForMenuItem = actionForMenuItem
      self.normalizeLastNum = normalizeLastNum
      self.numRange = numRange
      self.l10nKey = l10nKey
    }

    func sameKeyAction(_ keyBindingAction: [String]) -> (isMatch: Bool, value: Double?, extraData: Any?) {
      var lhs = keyBindingAction
      let rhs = actionForMenuItem
      var extraData: Any? = nil
      if lhs.first == "seek", rhs.first == "seek", lhs.count > 2, let last = lhs.last {
        // This is a seek command that includes flags. Adjust the command before checking for a match.
        if lhs.count == 4 {
          // The original mpv seek command required that the keyframes and exact flags be passed as a
          // 3rd parameter. This is considered deprecated but still supported by mpv. Convert this to
          // the current command format by combining the flags using a "+" separator.
          lhs[2] = "\(lhs[2])+\(lhs[3])"
          lhs = [String](lhs.dropLast())
        }
        var splitArray = last.split(whereSeparator: { $0 == "+" })
        if let index = splitArray.firstIndex(of: "relative") {
          // The mpv seek command seeks relative to current position by default. Because of that the
          // seek command used by menu items does not specify this flag. Ignore it when checking for a
          // match.
          splitArray.remove(at: index)
        }
        if let index = splitArray.firstIndex(of: "exact") {
          // Alter the behavior of the menu item by passing this flag on the side as extra data.
          splitArray.remove(at: index)
          extraData = Preference.SeekOption.exact
        }
        // NOTE at this time PlayerCore does not support specifying the keyframes flag, so it can't
        // be specified on the side as extra data as is done for exact. Although the mpv seek command
        // normally defaults to seeking by keyframes, that default can be changed by the hr-seek option.
        // When hr-seek has been set to enable exact seeks by default the keyframes flag will override
        // that default.
        if splitArray.isEmpty {
          // All flags were recognized as ones we do not need to consider when checking for a match.
          lhs = [String](lhs.dropLast())
        }
      }
      guard lhs.count > 0 && lhs.count == rhs.count else {
        return (false, nil, nil)
      }
      if normalizeLastNum {
        for i in 0..<lhs.count-1 {
          if lhs[i] != rhs[i] {
            return (false, nil, nil)
          }
        }
        guard let ld = Double(lhs.last!), let rd = Double(rhs.last!) else {
          return (false, nil, nil)
        }
        if let range = numRange {
          return (range.contains(ld), ld, extraData)
        } else {
          return (ld == rd, ld, extraData)
        }
      } else {
        for i in 0..<lhs.count {
          if lhs[i] != rhs[i] {
            return (false, nil, nil)
          }
        }
      }
      return (true, nil, nil)
    }

    /// Updates the key equivalent of the given menu item.
    /// May also update its title and representedObject, for items which can change based on some param value(s).
    func updateMenuItem(_ menuItem: NSMenuItem, keyEquiv: String, _ keyModifierMask: NSEvent.ModifierFlags,
                        value: Double?, extraData: Any?) {
      menuItem.keyEquivalent = keyEquiv
      menuItem.keyEquivalentModifierMask = keyModifierMask

      if let value = value, let l10nKey = l10nKey {
        menuItem.title = String(format: NSLocalizedString("menu." + l10nKey, comment: ""), abs(value).groupedStringUpTo6Decimals)
        if let extraData = extraData {
          menuItem.representedObject = (value, extraData)
        } else {
          menuItem.representedObject = value
        }
      } else {
        // Clear any previous value
        menuItem.representedObject = nil
      }
    }

  }  // end stuct BindableMenuItem

  // MARK: Set key equivalents

  /// Iterates over candidateBindings, and for those with attached menu items, update the menu items' key equivalents
  /// Two general groups to be processed:
  /// - Save filters & Plugin menu bindings have already had their values & enablement determined: just need to update their menu items.
  /// - MPV bindings need some additional checks to see if they can be associated with menu items.
  @MainActor
  func updateKeyEquivalents(in candidateBindings: inout [InputBinding]) {
    var mpvBindingIndexes: [Int] = []

    for (i, binding) in candidateBindings.enumerated() {
      switch binding.origin {
      case .iinaPlugin, .savedFilter:
        // include disabled bindings: need to set their menu item key equivs to nil
        let updatedBinding = updateKeyEquivalent(from: binding)
        candidateBindings[i] = updatedBinding
      case .confFile:
        if binding.isEnabled { // don't care about disabled bindings here
          mpvBindingIndexes.append(i)
        }
      default:
        break
      }
    }

    matchKeyEquivalents(with: mpvBindingIndexes, into: &candidateBindings)
  }

  @MainActor
  private func updateKeyEquivalent(from binding: InputBinding) -> InputBinding {
    guard let sectionMenuItems = sectionMappingItemPairs[binding.srcSectionName] else { return binding }
    guard let matchingPair = sectionMenuItems.first(where: { $0.0 == binding.keyMapping }) else { return binding }
    let menuItem = matchingPair.1

    if binding.isEnabled {
      let mpvKey = binding.keyMapping.normalizedMpvKey
      if let (kEqv, kMdf) = KeyCodeHelper.macOSKeyEquivalent(from: mpvKey) {
        menuItem.keyEquivalent = kEqv
        menuItem.keyEquivalentModifierMask = kMdf
        if DebugConfig.logBindingsRebuild {
          Logger.log.verbose("Set menu keyEquiv: \(mpvKey.quoted) → \(menuItem.menuPathDescription)")
        }
        let displayMessage = "This key binding will activate the menu item:\n\(menuItem.menuPathDescription)"
        return binding.shallowClone(displayMessage: displayMessage)
      } else {
        Logger.log.error("Failed to get MacOS menu item key equivalent for \(mpvKey.quoted)")
      }
    } else {
      // Conflict! Key binding already reserved
      menuItem.keyEquivalent = ""
      menuItem.keyEquivalentModifierMask = []
      if DebugConfig.logBindingsRebuild {
        Logger.log.verbose("Unset menu keyEquiv: \(menuItem.title.quoted)")
      }
    }
    return binding
  }

  @MainActor
  private func matchKeyEquivalents(with userBindingIndexes: [Int], into bindingList: inout [InputBinding]) {
    var otherActionsMenuItems: [NSMenuItem] = []
    var mappingItemPairs: [(KeyMapping, NSMenuItem)] = []

    /// Loop over all the list of menu items which can be matched with one or more `KeyMapping`s
    for bmi in bindableMenuItems {
      /// Loop over all key bindings. Examine each binding's action and see if it is equivalent to `menuItem`'s action
      var didBindMenuItem = false
      for bindingIndex in userBindingIndexes {
        let binding = bindingList[bindingIndex]
        let kb = binding.keyMapping
        guard kb.isIINACommand == bmi.iinaCmd else { continue }
        guard let action = kb.action else { continue }
        let (isMatch, value, extraData) = bmi.sameKeyAction(action)
        guard isMatch, let (keyEquivalent, keyModifierMask) = KeyCodeHelper.macOSKeyEquivalent(from: kb.normalizedMpvKey) else { continue }
        guard !keyModifierMask.contains(.numericPad) else { continue }
        /// If we got here, `KeyMapping`'s action qualifies for being bound to `menuItem`.
        let kbMenuItem: NSMenuItem

        if didBindMenuItem {
          /// This `KeyMapping` matches a menu item whose key equivalent was set from a different `KeyMapping`.
          /// There can only be one key equivalent per menu item, so we will create a duplicate menu item and put it in a hidden menu.
          kbMenuItem = NSMenuItem(title: bmi.menuItem.title, action: bmi.menuItem.action, keyEquivalent: "")
          kbMenuItem.tag = bmi.menuItem.tag
          otherActionsMenuItems.append(kbMenuItem)
        } else {
          /// This `KeyMapping` was the first match found for this menu item.
          kbMenuItem = bmi.menuItem
          didBindMenuItem = true
        }
        // #MenuItemKeyBinding
        bmi.updateMenuItem(kbMenuItem, keyEquiv: keyEquivalent, keyModifierMask, value: value, extraData: extraData)
        /// Make sure this is executed after `updateMenuItem()` to ensure it contains the accurate menu item title:
        let displayMessage = "This key binding will activate the menu item:\n\(kbMenuItem.menuPathDescription)"

        // [kludge] use non-empty sourceName field (not otherwise used for user conf bindings) to indicate has menu item
        let kbUpdated = KeyMapping(rawKey: kb.rawKey, rawAction: kb.rawAction, isIINACommand: kb.isIINACommand,
                                   comment: kb.comment, sourceName: kb.sourceName.isEmpty ? "XXX" : kb.sourceName)
        mappingItemPairs.append((kbUpdated, kbMenuItem))
        bindingList[bindingIndex] = binding.shallowClone(keyMapping: kbUpdated, displayMessage: displayMessage)
      }

      if !didBindMenuItem {
        // Need to regenerate `title` and `representedObject` from their default values.
        // This is needed for the case where the menu item previously matched to a key binding, but now there is no match.
        // Obviously this is a little kludgey, but it avoids having to do a big refactor and/or writing a bunch of new code.
        let (_, value, extraData) = bmi.sameKeyAction(bmi.actionForMenuItem)
        // An "alternate" menu item appear is intended to replace a "normal" menu item in the menu if its modifier key is held down
        // (typically Option). But this key needs to be specified in its modifier flags, or the item may never appear, or may appear
        // at the same time as its "normal" counterpart.
        let modifiers: NSEvent.ModifierFlags = bmi.menuItem.isAlternate ? [.option] : []
        bmi.updateMenuItem(bmi.menuItem, keyEquiv: "", modifiers, value: value, extraData: extraData)
      }
    }

    // Update hidden menu
    updateOtherKeyBindings(replacingAllWith: otherActionsMenuItems)

    sectionMappingItemPairs[MPVInputSection.Shared.USER_CONF_SECTION_NAME] = mappingItemPairs
  }


  func buildBindableMenuItems() -> [BindableMenuItem] {
    return [
      .init(showCurrentFileInFinder, iinaCmd: true, [IINACommand.showCurrentFileInFinder.rawValue]),
      .init(deleteCurrentFile, iinaCmd: true, [IINACommand.deleteCurrentFile.rawValue]),
      .init(savePlaylist, iinaCmd: true, [IINACommand.saveCurrentPlaylist.rawValue]),
      .init(quickSettingsVideo, iinaCmd: true, [IINACommand.videoPanel.rawValue]),
      .init(quickSettingsAudio, iinaCmd: true, [IINACommand.audioPanel.rawValue]),
      .init(quickSettingsSub, iinaCmd: true, [IINACommand.subPanel.rawValue]),
      .init(playlistPanel, iinaCmd: true, [IINACommand.playlistPanel.rawValue]),
      .init(chapterPanel, iinaCmd: true, [IINACommand.chapterPanel.rawValue]),
      .init(findOnlineSub, iinaCmd: true, [IINACommand.findOnlineSubs.rawValue]),
      .init(saveDownloadedSub, iinaCmd: true, [IINACommand.saveDownloadedSub.rawValue]),
      .init(flip, iinaCmd: true, [IINACommand.flip.rawValue]),
      .init(mirror, iinaCmd: true, [IINACommand.mirror.rawValue]),
      .init(biggerSize, iinaCmd: true, [IINACommand.biggerWindow.rawValue]),
      .init(smallerSize, iinaCmd: true, [IINACommand.smallerWindow.rawValue]),
      .init(fitToScreen, iinaCmd: true, [IINACommand.fitToScreen.rawValue],),
      .init(miniPlayer, iinaCmd: true, [IINACommand.toggleMusicMode.rawValue]),
      .init(liveText, iinaCmd: true, [IINACommand.liveText.rawValue]),
      .init(pictureInPicture, iinaCmd: true, [IINACommand.togglePIP.rawValue]),
      .init(cycleVideoTracks, iinaCmd: false, ["cycle", "video"]),
      .init(cycleAudioTracks, iinaCmd: false, ["cycle", "audio"]),
      .init(cycleSubtitles, iinaCmd: false, ["cycle", "sub"]),
      .init(nextChapter, iinaCmd: false, ["add", "chapter", "1"]),
      .init(previousChapter, iinaCmd: false, ["add", "chapter", "-1"]),
      .init(pause, iinaCmd: false, ["cycle", "pause"]),
      .init(stop, iinaCmd: false, ["stop"]),
      .init(forward, iinaCmd: false, ["seek", "5"], normalizeLastNum: true, 5.0...60.0, l10nKey: "seek_forward"),
      .init(backward, iinaCmd: false, ["seek", "-5"], normalizeLastNum: true, -60.0...(-5.0), l10nKey: "seek_backward"),
      .init(nextFrame, iinaCmd: false, ["frame-step"]),
      .init(previousFrame, iinaCmd: false, ["frame-back-step"]),
      .init(nextMedia, iinaCmd: false, ["playlist-next"]),
      .init(previousMedia, iinaCmd: false, ["playlist-prev"]),
      .init(speedUp, iinaCmd: false, ["multiply", "speed", "2.0"], normalizeLastNum: true, 1.5...3.0, l10nKey: "speed_up"),
      .init(speedUpSlightly, iinaCmd: false, ["multiply", "speed", "1.1"], normalizeLastNum: true, 1.01...1.49, l10nKey: "speed_up"),
      .init(speedDown, iinaCmd: false, ["multiply", "speed", "0.5"], normalizeLastNum: true, 0...0.7, l10nKey: "speed_down"),
      .init(speedDownSlightly, iinaCmd: false, ["multiply", "speed", "0.9"], normalizeLastNum: true, 0.71...0.99, l10nKey: "speed_down"),
      .init(speedReset, iinaCmd: false, ["set", "speed", "1.0"], normalizeLastNum: true),
      .init(abLoop, iinaCmd: false, ["ab-loop"]),
      .init(fileLoop, iinaCmd: false, ["cycle-values", "loop", "\"inf\"", "\"no\""]),
      .init(screenshot, iinaCmd: false, ["screenshot"]),
      .init(halfSize, iinaCmd: false, ["set", "window-scale", "0.5"], normalizeLastNum: true),
      .init(normalSize, iinaCmd: false, ["set", "window-scale", "1"], normalizeLastNum: true),
      .init(doubleSize, iinaCmd: false, ["set", "window-scale", "2"], normalizeLastNum: true),
      .init(fullScreen, iinaCmd: false, ["cycle", "fullscreen"]),
      .init(alwaysOnTop, iinaCmd: false, ["cycle", "ontop"]),
      .init(mute, iinaCmd: false, ["cycle", "mute"]),
      .init(increaseVolume, iinaCmd: false, ["add", "volume", "5"], normalizeLastNum: true, 5.0...10.0, l10nKey: "volume_up"),
      .init(decreaseVolume, iinaCmd: false, ["add", "volume", "-5"], normalizeLastNum: true, -10.0...(-5.0), l10nKey: "volume_down"),
      .init(increaseVolumeSlightly, iinaCmd: false, ["add", "volume", "1"], normalizeLastNum: true, 1.0...2.0, l10nKey: "volume_up"),
      .init(decreaseVolumeSlightly, iinaCmd: false, ["add", "volume", "-1"], normalizeLastNum: true, -2.0...(-1.0), l10nKey: "volume_down"),
      .init(decreaseAudioDelay, iinaCmd: false, ["add", "audio-delay", "-0.5"], normalizeLastNum: true, l10nKey: "audio_delay_down"),
      .init(decreaseAudioDelaySlightly, iinaCmd: false, ["add", "audio-delay", "-0.1"], normalizeLastNum: true, l10nKey: "audio_delay_down"),
      .init(increaseAudioDelay, iinaCmd: false, ["add", "audio-delay", "0.5"], normalizeLastNum: true, l10nKey: "audio_delay_up"),
      .init(increaseAudioDelaySlightly, iinaCmd: false, ["add", "audio-delay", "0.1"], normalizeLastNum: true, l10nKey: "audio_delay_up"),
      .init(resetAudioDelay, iinaCmd: false, ["set", "audio-delay", "0"], normalizeLastNum: true),
      .init(hideSubtitles, iinaCmd: false, ["cycle", "sub-visibility"]),
      .init(hideSecondSubtitles, iinaCmd: false, ["cycle", "secondary-sub-visibility"]),
      .init(hideSubtitles, iinaCmd: false, ["cycle", "sub-visibility"]),
      .init(hideSecondSubtitles, iinaCmd: false, ["cycle", "secondary-sub-visibility"]),
      .init(decreaseSubDelay, iinaCmd: false, ["add", "sub-delay", "-0.5"], normalizeLastNum: true, l10nKey: "sub_delay_down"),
      .init(decreaseSubDelaySlightly, iinaCmd: false, ["add", "sub-delay", "-0.1"], normalizeLastNum: true, l10nKey: "sub_delay_down"),
      .init(increaseSubDelay, iinaCmd: false, ["add", "sub-delay", "0.5"], normalizeLastNum: true, l10nKey: "sub_delay_up"),
      .init(increaseSubDelaySlightly, iinaCmd: false, ["add", "sub-delay", "0.1"], normalizeLastNum: true, l10nKey: "sub_delay_up"),
      .init(resetSubDelay, iinaCmd: false, ["set", "sub-delay", "0"], normalizeLastNum: true),
      .init(increaseTextSize, iinaCmd: false, ["multiply", "sub-scale", "1.1"], normalizeLastNum: true, 1.01...1.49),
      .init(decreaseTextSize, iinaCmd: false, ["multiply", "sub-scale", "0.9"], normalizeLastNum: true, 0.71...0.99),
      .init(resetTextSize, iinaCmd: false, ["set", "sub-scale", "1"], normalizeLastNum: true),
      .init(alwaysOnTop, iinaCmd: false, ["cycle", "ontop"]),
      .init(fullScreen, iinaCmd: false, ["cycle", "fullscreen"]),
      .init(pictureInPicture, iinaCmd: true, [IINACommand.togglePIP.rawValue]),
    ]
  }
}

