//
//  LanguageTokenField.swift
//  iina
//
//  Created by Collider LI on 12/4/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa

fileprivate let enableLookupLogging = false

// Token which represents a single language
fileprivate struct LangToken: Equatable, Hashable, CustomStringConvertible {
  let code: String?
  let editingString: String

  // As a displayed token, this is used as the displayString. When stored in prefs CSV, this is used as the V[alue]:
  var identifierString: String {
    code ?? normalizedEditingString
  }

  var description: String {
    return "LangToken(code: \(code?.quoted ?? "nil"), editStr: \(editingString.quoted))"
  }

  private var normalizedEditingString: String {
    self.editingString.lowercased().replacingOccurrences(of: ",", with: ";").trimmingCharacters(in: .whitespaces)
  }

  // Need the following to prevent NSTokenField doing an infinite loop

  func equalTo(_ rhs: LangToken) -> Bool {
    return self.editingString == rhs.editingString
  }

  static func ==(lhs: LangToken, rhs: LangToken) -> Bool {
    return lhs.equalTo(rhs)
  }

  static func !=(lhs: LangToken, rhs: LangToken) -> Bool {
    return !lhs.equalTo(rhs)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(editingString)
  }

  // If code is valid, looks up its description and uses it for `editingString`.
  // If code not found, falls back to init from editingString.
  static func from(code: String) -> LangToken {
    let matchingLangs = ISO639Helper.languages.filter({ $0.code == code })
    if !matchingLangs.isEmpty {
      let langDescription = matchingLangs[0].description
      return LangToken(code: code, editingString: langDescription)
    }
    return LangToken.from(editingString: code)
  }

  static func from(editingString: String) -> LangToken {
    return LangToken(code: nil, editingString: editingString)
  }
}

// A collection of unique languages (usually the field's entire contents)
fileprivate struct LangSet {
  let langTokens: [LangToken]

  init(langTokens: [LangToken]) {
    self.langTokens = langTokens
  }

  init(fromCSV csv: String) {
    self.init(langTokens: csv.isEmpty ? [] : csv.components(separatedBy: ",").map{ LangToken.from(code: $0.trimmingCharacters(in: .whitespaces)) })
  }

  init(fromObjectValue objectValue: Any?) {
    self.init(langTokens: (objectValue as? NSArray)?.compactMap({ ($0 as? LangToken) }) ?? [])
  }

  func toCSV() -> String {
    return langTokens.map{ $0.identifierString }.sorted().joined(separator: ",")
  }

  func toNewlineSeparatedString() -> String {
    return toCSV().replacingOccurrences(of: ",", with: "\n")
  }

  func contains(_ token: LangToken) -> Bool {
    return !langTokens.filter({ $0.identifierString == token.identifierString }).isEmpty
  }

  func deduplicated() -> LangSet {
    var uniques: [String: LangToken] = [:]
    for token in langTokens {
      uniques[token.identifierString] = token
    }
    return LangSet(langTokens: Array(uniques.values))
  }
}

class LanguageTokenField: NSTokenField {
  private var layoutManager: NSLayoutManager?

  // Should match the value from the prefs.
  // Is only changed when `commaSeparatedValues` is set, and by `submitChanges()`.
  private var savedSet = LangSet(langTokens: [])

  // may include unsaved tokens from the edit session
  fileprivate var objectValueLangSet: LangSet {
    LangSet(fromObjectValue: self.objectValue)
  }

  var commaSeparatedValues: String {
    get {
      let csv = savedSet.toCSV()
      Logger.log("LTF Generated CSV from savedSet: \(csv.quoted)", level: .verbose)
      return csv
    } set {
      Logger.log("LTF Setting savedSet from CSV: \(newValue.quoted)", level: .verbose)
      self.savedSet = LangSet(fromCSV: newValue)
      // Need to convert from CSV to newline-SV
      self.stringValue = self.savedSet.toNewlineSeparatedString()
    }
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    self.delegate = self
    self.tokenStyle = .rounded
    // Cannot use commas, because language descriptions are used as editing strings, and many of them contain commas, whitespace, quotes,
    // and NSTokenField will internally tokenize editing strings. We should be able to keep using CSV in the prefs
    self.tokenizingCharacterSet = .newlines
  }

  @objc func controlTextDidEndEditing(_ notification: Notification) {
    Logger.log("LTF Calling action from controlTextDidEndEditing()", level: .verbose)
    submitChanges()
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let layoutManager = layoutManager else { return }
    let attachmentChar = Character(UnicodeScalar(NSTextAttachment.character)!)
    let finished = layoutManager.attributedString().string.split(separator: attachmentChar).count == 0
    if finished {
      Logger.log("LTF Committing changes from controlTextDidChange()", level: .verbose)
      submitChanges()
    }
  }

  override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
    if let view = textObject as? NSTextView {
      layoutManager = view.layoutManager
    }
    return true
  }

  func submitChanges() {
    let langSetNew = self.objectValueLangSet.deduplicated()
    makeUndoableUpdate(to: langSetNew)
  }

  private func makeUndoableUpdate(to langSetNew: LangSet) {
    let langSetOld = self.savedSet
    let csvOld = langSetOld.toCSV()
    let csvNew = langSetNew.toCSV()

    Logger.log("LTF Updating: Old: \(csvOld.quoted) New: \(csvNew.quoted)}", level: .verbose)
    if csvOld == csvNew {
      Logger.log("LTF No changes to lang set", level: .verbose)
    } else {
      self.savedSet = langSetNew
      if let target = target, let action = action {
        target.performSelector(onMainThread: action, with: self, waitUntilDone: false)
      }

      // Register for undo or redo. Needed because the change to stringValue below doesn't include it
      if let undoManager = self.undoManager {
        undoManager.registerUndo(withTarget: self, handler: { languageTokenField in
          self.makeUndoableUpdate(to: langSetOld)
        })
      }
    }

    // Update displayed list. Even if there were no changes, there may have been changes to sorting, or duplicates removed.
    self.stringValue = langSetNew.toNewlineSeparatedString()
  }
}

extension LanguageTokenField: NSTokenFieldDelegate {

  func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
    // Tokens never have a context menu
    return false
  }

  // Returns array of auto-completion results for user's typed string (`substring`)
  func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                  indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
    let lowSubString = substring.lowercased()
    let currentLangCodes = Set(self.savedSet.langTokens.compactMap{$0.code})
    let matches = ISO639Helper.languages.filter { lang in
      return !currentLangCodes.contains(lang.code) && lang.name.contains { $0.lowercased().hasPrefix(lowSubString) }
    }
    let descriptions = matches.map { $0.description }
    if enableLookupLogging {
      Logger.log("LTF given substring: \(substring.quoted) -> returning completions: \(descriptions)", level: .verbose)
    }
    return descriptions
  }

  // Called by AppKit. Token -> DisplayStringString. Returns the string to use when displaying as a token
  func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
    guard let token = representedObject as? LangToken else { return nil }

    if enableLookupLogging {
      Logger.log("LTF given token: \(token) -> returning displayString \(token.identifierString.quoted)", level: .verbose)
    }
    return token.identifierString
  }

  // Called by AppKit. Token -> EditingString. Returns the string to use when editing a token.
  func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
    guard let token = representedObject as? LangToken else { return nil }

    if enableLookupLogging {
      Logger.log("LTF given token: \(token) -> returning editingString \(token.editingString.quoted)", level: .verbose)
    }
    return token.editingString
  }

  // Called by AppKit. EditingString -> Token
  func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
    // Return language code (if possible)
    let token: LangToken
    if let langCode = ISO639Helper.descriptionRegex.captures(in: editingString)[at: 1] {
      token  = LangToken.from(code: langCode)
      if enableLookupLogging {
        Logger.log("LTF given editingString: \(editingString.quoted) -> found match, returning \(token)", level: .verbose)
      }
    } else {
      token = LangToken.from(editingString: editingString)
      if enableLookupLogging {
        Logger.log("LTF given editingString: \(editingString.quoted), -> no code; returning \(token)", level: .verbose)
      }
    }
    return token
  }

  // Serializes an array of LangToken objects into a string of CSV (cut/copy/paste support)
  // Need to override this because it will default to using `tokenizingCharacterSet`, which needed to be overriden for
  // internal parsing of `editingString`s to work correctly, but we want to use CSV when exporting `identifierString`s
  // because they are more user-readable.
  func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
    guard let tokens = objects as? [LangToken] else {
      return false
    }
    let langSet = LangSet(langTokens: tokens)

    pboard.clearContents()
    pboard.setString(langSet.toCSV(), forType: NSPasteboard.PasteboardType.string)
    return true
  }

  // Parses CSV from the given pasteboard and returns an array of LangToken objects (cut/copy/paste support)
  // See note for `tokenField(writeRepresentedObjects....)` above.
  func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
    if let pbString = pboard.string(forType: NSPasteboard.PasteboardType.string) {
      return LangSet(fromCSV: pbString).langTokens
    }
    return []
  }
}
