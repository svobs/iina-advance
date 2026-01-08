//
//  FocusedTableCell.swift
//  iina
//
//  Created by Matt Svoboda on 10/8/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

// Plays the role of mediator: coordinates between EditableTableView and its EditableTextFields, to manage
// in-line cell editing.
@MainActor
class CellEditTracker: NSObject, NSTextFieldDelegate {
  // Stores info for the currently focused cell, whether or not the cell is being edited
  struct CurrentFocus {
    let textField: EditableTextField
    let stringValueOrig: String
    let row: Int
    let column: Int
    /// If true, `current` has had `startEdit()` called but not `endEdit()`.
    let editInProgress: Bool
  }
  var current: CurrentFocus? = nil

  private var parentTable: EditableTableView {  delegate.parentTableView }
  private let delegate: EditableTableViewDelegate
  var log: any Logger.Subsystem { parentTable.log }

  init(delegate: EditableTableViewDelegate) {
    self.delegate = delegate
  }

  var isEditInProgress: Bool {
    current?.editInProgress ?? false
  }

  private func getTextMovementName(from notification: Notification) -> String {
    guard let textMovementInt = notification.userInfo?["NSTextMovement"] as? Int else {
      return "nil"
    }

    let tm = NSTextMovement(rawValue: textMovementInt)
    switch tm {
    case .return:
      return "return"
    case .backtab:
      return "backtab"
    case .cancel:
      return "cancel"
    case .left:
      return "left"
    case .right:
      return "right"
    case .up:
      return "up"
    case .down:
      return "down"
    case .other:
      return "other"
    case .tab:
      return "tab"
    default:
      return "{\(textMovementInt)}"
    }
  }

  @objc func controlTextDidEndEditing(_ notification: Notification) {
    log.verbose("DidEndEditing (nextNav: \(getTextMovementName(from: notification)))")

    guard let current else {
      return
    }

    endEdit()

    // Tab / return navigation (if any) will show up in the notification
    if let textMovementInt = notification.userInfo?["NSTextMovement"] as? Int,
       let textMovement = NSTextMovement(rawValue: textMovementInt) {

      DispatchQueue.main.async { [self] in
        // Start asynchronously so we can return
        guard let (newRowIndex, newColIndex) = editAnotherCellAfterEditEnd(oldRow: current.row, oldColumn: current.column, textMovement) else { return }
        parentTable.editCell(row: newRowIndex, column: newColIndex)
      }
    }
  }

  func changeCurrentCell(to textField: EditableTextField, row: Int, column: Int) {
    // Close old editor, if any:
    if let prev = self.current {
      if row == prev.row && column == prev.column && textField == prev.textField {
        return
      } else {
        log.verbose("CellEditTracker: changing cell from (\(prev.row), \(prev.column)) to (\(row), \(column))")
        // Make sure old editor is closed and saved if appropriate:
        endEdit()
      }
    } else {
      log.verbose("CellEditTracker: changing cell to (\(row), \(column))")
    }
    // keep track of it all
    self.current = CurrentFocus(textField: textField, stringValueOrig: textField.stringValue, row: row, column: column, editInProgress: false)
    textField.delegate = self
    textField.editTracker = self
    if !parentTable.isEnabled {
      // deselect rows if not enabled
      parentTable.selectApprovedRowIndexes(IndexSet())
    }
  }

  func startEdit() {
    guard let current = current else {
      return
    }

    let textField = current.textField
    log.verbose("START Edit [\(current.row), \(current.column)] \"\(textField.stringValue)\"")
    self.current = CurrentFocus(textField: textField, stringValueOrig: textField.stringValue, row: current.row, column: current.column, editInProgress: true)
    textField.isEditable = true
    textField.isSelectable = true
    textField.textColor = .controlTextColor // Reset any custom coloring

    // Prevent field editor from collapsing to the height of a single line during editing.
    // This unfortunately doesn't support live updates to the height during editing even when lines are added or removed.
    // But should be "good enough" for now.
    textField.heightConstraint = textField.heightAnchor.constraint(equalToConstant: textField.frame.height)
    textField.heightConstraint?.isActive = true

    textField.selectText(nil)  // creates editor
    textField.needsDisplay = true
  }

  private func commitChanges(to current: CurrentFocus) -> Bool {
    if current.textField.stringValue == current.stringValueOrig {
      log.verbose("endEdit() calling editDidEndWithNoChange()")
      delegate.editDidEndWithNoChange(row: current.row, column: current.column)
      return false
    }

    guard delegate.parentTableView.editableTextColumnIndexes.contains(current.column) else {
      Logger.fatal("endEdit(): invalid column index: \(current.column)")  // programmer error
    }

    let wasAccepted = delegate.editDidEndWithNewText(newValue: current.textField.stringValue, row: current.row, column: current.column)
    if wasAccepted {
      log.verbose("editDidEndWithNewText() returned TRUE: assuming new value accepted")
      return true
    }

    // a return value of false tells us to revert to the previous value
    log.verbose("editDidEndWithNewText() returned FALSE: reverting displayed value to \"\(current.stringValueOrig)\"")
    current.textField.stringValue = current.stringValueOrig
    return false
  }

  func endEdit() {
    guard let current = current, current.editInProgress else { return }

    let textField = current.textField
    log.verbose("END Edit   [\(current.row), \(current.column)] \"\(textField.stringValue)\"")

    let didSucceed = commitChanges(to: current)

    textField.heightConstraint?.isActive = false
    textField.heightConstraint = nil

    self.current = CurrentFocus(textField: textField, stringValueOrig: textField.stringValue, row: current.row, column: current.column, editInProgress: false)

    textField.window?.endEditing(for: textField)
    // Resign first responder status and give focus back to table row selection:
    textField.window?.makeFirstResponder(self.parentTable)
    textField.isEditable = false
    textField.isSelectable = false
    textField.needsDisplay = true

    guard didSucceed else { return }

    // Load custom color or other cell changes based on new value:
    parentTable.reloadRow(current.row)
  }

  // MARK: Intercellular edit navigation

  func askUserToApproveDoubleClickEdit() -> Bool {
    if let current = current {
      guard self.parentTable.isEnabled else {
        // deselect rows
        log.verbose("Table is not enabled, deselecting row(s)")
        self.parentTable.selectApprovedRowIndexes(IndexSet())
        return false
      }
      return self.delegate.userDidDoubleClickOnCell(row: current.row, column: current.column)
    }
    log.verbose("No current focused cell; auto-denying double-click")
    return false
  }

  private func getIndexOfEditableColumn(_ columnIndex: Int) -> Int? {
    let editColumns = self.parentTable.editableTextColumnIndexes
    for (indexIndex, index) in editColumns.enumerated() {
      if columnIndex == index {
        return indexIndex
      }
    }
    log.error("Failed to find index \(columnIndex) in editableTextColumnIndexes (\(editColumns))")
    return nil
  }

  private func nextTabColumnIndex(_ columnIndex: Int) -> Int {
    let editColumns = self.parentTable.editableTextColumnIndexes
    if let indexIndex = getIndexOfEditableColumn(columnIndex) {
      return editColumns[(indexIndex+1) %% editColumns.count]
    }
    return editColumns[0]
  }

  private func prevTabColumnIndex(_ columnIndex: Int) -> Int {
    let editColumns = self.parentTable.editableTextColumnIndexes
    if let indexIndex = getIndexOfEditableColumn(columnIndex) {
      return editColumns[(indexIndex-1) %% editColumns.count]
    }
    return editColumns[0]
  }

  /// Thanks to:
  /// https://samwize.com/2018/11/13/how-to-tab-to-next-row-in-nstableview-view-based-solution/
  /// Returns `true` if it resulted in another editor being opened [asychronously], `false` if not.
  /// Currently, {`up`, `down`, `left`, `right`} text movements are not supported, but may be in the future.
  @discardableResult
  func editAnotherCellAfterEditEnd(oldRow rowIndex: Int, oldColumn columnIndex: Int, _ textMovement: NSTextMovement) -> (newEditRow: Int, newEditCol: Int)? {
    let isInterRowTabEditingEnabled = Preference.bool(for: .tableEditKeyNavContinuesBetweenRows)

    var newRowIndex: Int
    var newColIndex: Int
    switch textMovement {
    case .tab:
      // Snake down the grid, left to right, top down
      newColIndex = nextTabColumnIndex(columnIndex)
      if newColIndex < 0 {
        log.error("Invalid value for next column: \(newColIndex)")
        return nil
      }
      if newColIndex <= columnIndex {
        guard isInterRowTabEditingEnabled else {
          return nil
        }
        newRowIndex = rowIndex + 1
        if newRowIndex >= self.parentTable.numberOfRows {
          // Always done after last row
          return nil
        }
      } else {
        newRowIndex = rowIndex
      }
    case .backtab:
      // Snake up the grid, right to left, bottom up
      newColIndex = prevTabColumnIndex(columnIndex)
      if newColIndex < 0 {
        log.error("Invalid value for prev column: \(newColIndex)")
        return nil
      }
      if newColIndex >= columnIndex {
        guard isInterRowTabEditingEnabled else {
          return nil
        }
        newRowIndex = rowIndex - 1
        if newRowIndex < 0 {
          return nil
        }
      } else {
        newRowIndex = rowIndex
      }
    case .up:
      guard isInterRowTabEditingEnabled else {
        return nil
      }
      newRowIndex = rowIndex - 1
      if newRowIndex < 0 {
        return nil
      }
      newColIndex = columnIndex
    case .return:
      // Always just end editing when RETURN/ENTER is pressed.
      return nil
    case .down:
      guard isInterRowTabEditingEnabled else {
        return nil
      }
      // Go to cell directly below
      newRowIndex = rowIndex + 1
      if newRowIndex >= self.parentTable.numberOfRows {
        // Always done after last row
        return nil
      }
      newColIndex = columnIndex
    default: return nil
    }

    // handled
    return (newRowIndex, newColIndex)
  }

}
