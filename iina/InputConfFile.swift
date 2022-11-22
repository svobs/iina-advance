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
  enum Status {
    case failedToLoad
    case readOnly
    case normal
  }
  let status: Status

  // The path of the source file on disk
  let filePath: String

  // This should reflect what is on disk at all times
  private let lines: [String]

  fileprivate init(filePath: String, status: Status, lines: [String]) {
    self.filePath = filePath
    self.status = status
    self.lines = lines
  }

  var isReadOnly: Bool {
    return self.status == .readOnly
  }

  var failedToLoad: Bool {
    return self.status == .failedToLoad
  }

  // This parses the file's lines one by one, skipping lines which are blank or only comments, If a line looks like a key binding,
  // a KeyMapping object is constructed for it, and each KeyMapping makes note of the line number from which it came. A list of the successfully
  // constructed KeyMappings is returned once the entire file has been parsed.
  func parseMappings() -> [KeyMapping] {
    return self.lines.compactMap({ InputConfFile.parseRawLine($0) })
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

  private static func toRawLines(from mappings: [KeyMapping]) -> [String] {
    var newLines: [String] = []
    newLines.append("# Generated by IINA")
    newLines.append("")
    for mapping in mappings {
      let rawLine = mapping.confFileFormat
      if InputConfFile.parseRawLine(rawLine) == nil {
        Logger.log("While serializing key mappings: looks like an unfinished addition: \(mapping)", level: .verbose)
      } else {
        // valid binding
        newLines.append(rawLine)
      }
    }
    return newLines
  }

  func overwriteFile(with newMappings: [KeyMapping]) throws -> InputConfFile {
    guard !isReadOnly else {
      Logger.log("overwriteFile(): aborting - isReadOnly==true!", level: .error)
      throw IINAError.confFileIsReadOnly
    }
    let rawLines = InputConfFile.toRawLines(from: newMappings)

    let updatedConfFile = InputConfFile(filePath: self.filePath, status: .normal, lines: rawLines)
    try updatedConfFile.saveFile()
    return updatedConfFile
  }

  func saveFile() throws {
    let newFileContent: String = self.lines.joined(separator: "\n")
    try newFileContent.write(toFile: self.filePath, atomically: true, encoding: .utf8)
  }

  // Check returned object's `status` property; make sure `!= .failedToLoad`
  static func loadFile(at path: String, isReadOnly: Bool = true) -> InputConfFile {
    guard let reader = StreamReader(path: path) else {
      // on error
      Logger.log("Error loading key bindings from path: \"\(path)\"", level: .error)
      let fileName = URL(fileURLWithPath: path).lastPathComponent
      let alertInfo = Utility.AlertInfo(key: "keybinding_config.error", args: [fileName])
      NotificationCenter.default.post(Notification(name: .iinaKeyBindingErrorOccurred, object: alertInfo))
      return InputConfFile(filePath: path, status: .failedToLoad, lines: [])
    }

    var lines: [String] = []
    while let rawLine: String = reader.nextLine() {
      guard lines.count < AppData.maxConfFileLinesAccepted else {
        Logger.log("Maximum number of lines (\(AppData.maxConfFileLinesAccepted)) exceeded: stopping load of file: \"\(path)\"")
        return InputConfFile(filePath: path, status: .failedToLoad, lines: [])
      }
      lines.append(rawLine)
    }

    let status: Status = isReadOnly ? .readOnly : .normal
    return InputConfFile(filePath: path, status: status, lines: lines)
  }
}
