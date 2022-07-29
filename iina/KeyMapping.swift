//
//  KeyMap.swift
//  iina
//
//  Created by lhc on 12/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Foundation

/// - Tag: KeyMapping
class KeyMapping: NSObject {

  var isIINACommand: Bool

  var rawKey: String {
    didSet {
      self.normalizedMpvKey = KeyCodeHelper.normalizeMpv(rawKey)
    }
  }

  private(set) var normalizedMpvKey: String

  // For UI
  var prettyKey: String {
    get {
      if let (keyChar, modifiers) = KeyCodeHelper.macOSKeyEquivalent(from: normalizedMpvKey, usePrintableKeyName: true) {
        return KeyCodeHelper.readableString(fromKey: keyChar, modifiers: modifiers)
      } else {
        return normalizedMpvKey
      }
    }
  }

  // This is a rare occurrence. The section, if it exists, will be the first element in `action` and will be surrounded by curly braces.
  // Leave it inside `rawAction` and `action` so that it will be easy to edit in the UI.
  var section: String? {
    get {
      if action.count > 1 && action[0].count > 0 && action[0][action[0].startIndex] == "{" {
        if let endIndex = action[0].firstIndex(of: "}") {
          let inner = action[0][action[0].index(after: action[0].startIndex)..<endIndex]
          return inner.trimmingCharacters(in: .whitespaces)
        }
      }
      return nil
    }
  }

  private(set) var action: [String]

  private var privateRawAction: String

  var rawAction: String {
    set {
      if let trimmedAction = KeyMapping.removeIINAPrefix(from: newValue) {
        self.isIINACommand = true
        self.privateRawAction = trimmedAction
      } else {
        self.isIINACommand = false
        self.privateRawAction = newValue
      }
      action = privateRawAction.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }
    get {
      return privateRawAction
    }
  }

  var comment: String?

  @objc var readableAction: String {
    get {
      let joined = action.joined(separator: " ")
      return isIINACommand ? ("@iina " + joined) : joined
    }
  }

  var isIgnored: Bool {
    return privateRawAction == MPVCommand.ignore.rawValue
  }

  // For UI
  var prettyCommand: String {
    return KeyBindingTranslator.readableCommand(fromAction: action, isIINACommand: isIINACommand)
  }

  var confFileFormat: String {
    get {
      let iinaCommandString = isIINACommand ? "#@iina " : ""
      let commentString = (comment == nil || comment!.isEmpty) ? "" : "   #\(comment!)"
      return "\(iinaCommandString)\(rawKey) \(action.joined(separator: " "))\(commentString)"
    }
  }

  init(rawKey: String, rawAction: String, isIINACommand: Bool = false, comment: String? = nil) {
    self.isIINACommand = isIINACommand
    self.privateRawAction = rawAction
    if let trimmedAction = KeyMapping.removeIINAPrefix(from: rawAction) {
      self.isIINACommand = true
      self.privateRawAction = trimmedAction
    }
    self.rawKey = rawKey
    self.normalizedMpvKey = KeyCodeHelper.normalizeMpv(rawKey)
    self.comment = comment
    self.action = rawAction.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
  }

  private static func removeIINAPrefix(from rawAction: String) -> String? {
    if rawAction.hasPrefix("@iina") {
      return rawAction[rawAction.index(rawAction.startIndex, offsetBy: "@iina".count)...].trimmingCharacters(in: .whitespaces)
    } else {
      return nil
    }
  }

  public override var description: String {
    return "KeyMapping(\"\(rawKey)\"->\"\(action.joined(separator: " "))\" iina=\(isIINACommand))"
  }

  // MARK: Static functions

  // Returns nil if cannot read file
  static func parseInputConf(at path: String) -> [KeyMapping]? {
    guard let reader = StreamReader(path: path) else {
      return nil
    }
    var mapping: [KeyMapping] = []
    while var line: String = reader.nextLine() {      // ignore empty lines
      var isIINACommand = false
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      } else if line.hasPrefix("#") {
        if line.hasPrefix("#@iina") {
          // extended syntax
          isIINACommand = true
          line = String(line[line.index(line.startIndex, offsetBy: "#@iina".count)...])
        } else {
          // ignore comment line
          continue
        }
      }
      var comment: String? = nil
      if let sharpIndex = line.firstIndex(of: "#") {
        comment = String(line[line.index(after: sharpIndex)...])
        line = String(line[...line.index(before: sharpIndex)])
      }
      // split
      let splitted = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t"})
      if splitted.count < 2 {
        Logger.log("Skipped corrupted line in input.conf: \(line)", level: .warning)
        continue  // no command, wrong format
      }
      let key = String(splitted[0]).trimmingCharacters(in: .whitespaces)
      let action = String(splitted[1]).trimmingCharacters(in: .whitespaces)

      mapping.append(KeyMapping(rawKey: key, rawAction: action, isIINACommand: isIINACommand, comment: comment))
    }
    return mapping
  }

  static func generateInputConf(from mappings: [KeyMapping]) -> String {
    return mappings.reduce("# Generated by IINA\n\n", { prevLines, km in prevLines + "\(km.confFileFormat)\n" })
  }
}
