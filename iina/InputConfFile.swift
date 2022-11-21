//
//  InputConfFile.swift
//  iina
//
//  Created by Matt Svoboda on 2022.08.10.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

// Represents an input config file which has been loaded into memory.
struct InputConfFile {
  // At least one of its fields should be non-nil.
  // Only Lines with non-nil `rawFileContent` are present in the file on disk.
  // A Line struct can include additional in-memory state (if `bindingOverride` is non-nil) which is not present on disk.
  fileprivate struct Line {
    let rawFileContent: String?  // reflects content on disk
    let bindingOverride: KeyMapping?  // only exists in memory. Useful for maintaining edits even while they are not parseable

    init(_ rawFileContent: String? = nil, bindingOverride: KeyMapping? = nil) {
      self.rawFileContent = rawFileContent
      self.bindingOverride = bindingOverride
    }
  }

  let isReadOnly: Bool

  // The path of the source file on disk
  let filePath: String

  // This should reflect what is on disk at all times
  private let lines: [Line]

  fileprivate init(filePath: String, isReadOnly: Bool, lines: [Line]) {
    self.filePath = filePath
    self.isReadOnly = isReadOnly
    self.lines = lines
  }

  // This parses the file's lines one by one, skipping lines which are blank or only comments, If a line looks like a key binding,
  // a KeyMapping object is constructed for it, and each KeyMapping makes note of the line number from which it came. A list of the successfully
  // constructed KeyMappings is returned once the entire file has been parsed.
  func parseMappings() -> [KeyMapping] {
    var mappingList: [KeyMapping] = []

    var linesNew: [Line] = []
    for line in self.lines {
      if let binding = line.bindingOverride {
        // Note: `lineIndex` includes bindingOverrides and thus may be greater than the equivalent line number in the physical file
        mappingList.append(binding)
      } else if let rawFileContent = line.rawFileContent, let binding = InputConfFile.parseRawLine(rawFileContent) {
        mappingList.append(binding)
        linesNew.append(line)
      }
    }

    return mappingList
  }

  // Returns a KeyMapping if successful, nil if line has no mapping or is not correct format
  static func parseRawLine(_ rawLine: String) -> KeyMapping? {
    var content = rawLine
    var isIINACommand = false
    if content.trimmingCharacters(in: .whitespaces).isEmpty {
      return nil
    } else if content.hasPrefix("#") {
      if content.hasPrefix(KeyMapping.IINA_PREFIX) {
        // extended syntax
        isIINACommand = true
        content = String(content[content.index(content.startIndex, offsetBy: KeyMapping.IINA_PREFIX.count)...])
      } else {
        // ignore comment line
        return nil
      }
    }
    var comment: String? = nil
    if let sharpIndex = content.firstIndex(of: "#") {
      comment = String(content[content.index(after: sharpIndex)...])
      content = String(content[...content.index(before: sharpIndex)])
    }
    // split
    let splitted = content.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t"})
    if splitted.count < 2 {
      return nil  // no command, wrong format
    }
    let key = String(splitted[0]).trimmingCharacters(in: .whitespaces)
    let action = String(splitted[1]).trimmingCharacters(in: .whitespaces)

    return KeyMapping(rawKey: key, rawAction: action, isIINACommand: isIINACommand, comment: comment)
  }

  private static func toLines(from mappings: [KeyMapping]) -> [Line] {
    var newLines: [Line] = []
    newLines.append(Line("# Generated by IINA"))
    newLines.append(Line(""))
    for mapping in mappings {
      let rawLine = mapping.confFileFormat
      if InputConfFile.parseRawLine(rawLine) == nil {
        Logger.log("While serializing bindings: looks like an active edit: \(mapping)", level: .verbose)
        // line was added
        newLines.append(Line(bindingOverride: mapping))
      } else {
        // valid binding
        newLines.append(Line(rawLine))
      }
    }
    return newLines
  }

  func overwriteFile(with newMappings: [KeyMapping]) throws -> InputConfFile {
    guard !isReadOnly else {
      Logger.log("overwriteFile(): aborting - isReadOnly==true!", level: .error)
      throw IINAError.confFileIsReadOnly
    }
    let lines = InputConfFile.toLines(from: newMappings)
    let fileContent: String = lines.filter({ $0.rawFileContent != nil}).map({ $0.rawFileContent! }).joined(separator: "\n")
    try fileContent.write(toFile: self.filePath, atomically: true, encoding: .utf8)
    return InputConfFile(filePath: self.filePath, isReadOnly: self.isReadOnly, lines: lines)
  }

  // Returns nil if cannot read file
  static func loadFile(at path: String, isReadOnly: Bool = true) -> InputConfFile? {
    guard let reader = StreamReader(path: path) else {
      // on error
      Logger.log("Error loading key bindings from path: \"\(path)\"", level: .error)
      let fileName = URL(fileURLWithPath: path).lastPathComponent
      let alertInfo = Utility.AlertInfo(key: "keybinding_config.error", args: [fileName])
      NotificationCenter.default.post(Notification(name: .iinaKeyBindingErrorOccurred, object: alertInfo))

      return nil
    }

    var lines: [Line] = []

    while let rawFileContent: String = reader.nextLine() {      // ignore empty lines
      if lines.count >= AppData.maxConfFileLinesAccepted {
        Logger.log("Maximum number of lines (\(AppData.maxConfFileLinesAccepted)) exceeded: stopping load of file: \"\(path)\"")
        return nil
      }
      lines.append(Line(rawFileContent))
    }
    return InputConfFile(filePath: path, isReadOnly: isReadOnly, lines: lines)
  }

}
