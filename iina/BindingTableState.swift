//
//  BindingTableState.swift
//  iina
//
//  Created by Matt Svoboda on 9/20/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

/*
 Represents a snapshot of the state of tbe Key Bindings table, closely tied to an instance of `AppInputConfig.
 Like `AppInputConfig`, each instance is read-only and is designed to be rebuilt & replaced each time there is a change,
 to help ensure the integrity of its data. See `BindingTableStateManager` for all changes.
 Provides create/remove/update/delete operations on the table, and also completely handles filtering,  but is decoupled from UI code so that everything is cleaner.
 Should not contain any API calls to UI code. Other classes should call this class's public methods to get & update data.
 This class is downstream from `AppInputConfig.current`
 */
struct BindingTableState {

  init(_ appInputConfig: AppInputConfig, filterString: String, inputConfigFile: InputConfigFile?) {
    self.appInputConfig = appInputConfig
    self.filterString = filterString
    self.bindingRowsFiltered = BindingTableState.filter(bindingRowsAll: appInputConfig.bindingCandidateList, by: filterString)
    self.inputConfigFile = inputConfigFile
  }

  // MARK: Data

  // The state of the AppInputConfig on which the state of this table is based.
  // While in almost all cases this should be identical to AppInputConfig.current, it is way simpler and more performant
  // to allow some tiny amount of drift. We treat each AppInputConfig object as a read-only version of the application state,
  // and each new AppInputConfig is an atomic update which replaces the previously received one via asynchronous updates.
  let appInputConfig: AppInputConfig

  // The source user conf file
  let inputConfigFile: InputConfigFile?

  // Should be kept current with the value which the user enters in the search box:
  let filterString: String

  // The table rows currently displayed, which will change depending on the current filterString
  let bindingRowsFiltered: [InputBinding]

  // The current unfiltered list of table rows
  private var bindingRowsAll: [InputBinding] {
    appInputConfig.bindingCandidateList
  }

  // MARK: Bindings Table CRUD

  var bindingRowCount: Int {
    return bindingRowsFiltered.count
  }

  // Avoids hard program crash if index is invalid (which would happen for array dereference)
  func getBindingRow(at index: Int) -> InputBinding? {
    guard index >= 0 && index < bindingRowsFiltered.count else {
      return nil
    }
    return bindingRowsFiltered[index]
  }

  func moveBindings(_ mappingList: [KeyMapping], to index: Int, isAfterNotAt: Bool = false,
                    afterComplete: TableChange.CompletionHandler? = nil) -> Int {
    let insertIndex = getClosestValidInsertIndex(from: index, isAfterNotAt: isAfterNotAt)
    Logger.log("Movimg \(mappingList.count) bindings \(isAfterNotAt ? "after" : "to") to filtered index \(index), which equates to insert at unfiltered index \(insertIndex)", level: .verbose)

    let movedBindingIDs = Set(mappingList.map { $0.bindingID! })

    // Divide all the rows into 3 groups: before + after the insert, + the insert itself.
    // Since each row will be moved in order from top to bottom, it's fairly easy to calculate where each row will go
    var beforeInsert: [InputBinding] = []
    var afterInsert: [InputBinding] = []
    var movedRows: [InputBinding] = []
    var moveIndexPairs: [(Int, Int)] = []
    var newSelectedRows = IndexSet()
    var moveFromOffset = 0
    var moveToOffset = 0

    // Drag & Drop reorder algorithm: https://stackoverflow.com/questions/2121907/drag-drop-reorder-rows-on-nstableview
    for (origIndex, row) in bindingRowsAll.enumerated() {
      if let bindingID = row.keyMapping.bindingID, movedBindingIDs.contains(bindingID) {
        if origIndex < insertIndex {
          // If we moved the row from above to below, all rows up to & including its new location get shifted up 1
          moveIndexPairs.append((origIndex + moveFromOffset, insertIndex - 1))
          newSelectedRows.insert(insertIndex + moveFromOffset - 1)
          moveFromOffset -= 1
        } else {
          moveIndexPairs.append((origIndex, insertIndex + moveToOffset))
          newSelectedRows.insert(insertIndex + moveToOffset)
          moveToOffset += 1
        }
        movedRows.append(row)
      } else if origIndex < insertIndex {
        beforeInsert.append(row)
      } else {
        afterInsert.append(row)
      }
    }
    let bindingRowsAllUpdated = beforeInsert + movedRows + afterInsert

    let tableChange = TableChange(.moveRows, completionHandler: afterComplete)
    Logger.log("MovePairs: \(moveIndexPairs)", level: .verbose)
    tableChange.toMove = moveIndexPairs
    tableChange.newSelectedRows = newSelectedRows

    doAction(bindingRowsAllUpdated, tableChange)
    return insertIndex
  }

  func insertNewBindings(relativeTo index: Int, isAfterNotAt: Bool = false, _ mappingList: [KeyMapping],
                         afterComplete: TableChange.CompletionHandler? = nil) {
    let insertIndex = getClosestValidInsertIndex(from: index, isAfterNotAt: isAfterNotAt)
    Logger.log("Inserting \(mappingList.count) bindings \(isAfterNotAt ? "after" : "into") unfiltered row index \(index) -> insert at \(insertIndex)", level: .verbose)
    guard canModifyCurrentConfig else {
      Logger.log("Aborting: cannot modify current config!", level: .error)
      return
    }

    let tableChange = TableChange(.addRows, completionHandler: afterComplete)
    let toInsert = IndexSet(insertIndex..<(insertIndex+mappingList.count))
    tableChange.toInsert = toInsert
    tableChange.newSelectedRows = toInsert

    var bindingRowsAllNew = bindingRowsAll
    for mapping in mappingList.reversed() {
      // We can get away with making these assumptions about InputBinding fields, because only the "default" section can be modified by the user
      bindingRowsAllNew.insert(InputBinding(mapping, origin: .confFile, srcSectionName: SharedInputSection.DEFAULT_SECTION_NAME), at: insertIndex)
    }

    doAction(bindingRowsAllNew, tableChange)
  }

  // Returns the index at which it was ultimately inserted
  func insertNewBinding(relativeTo index: Int, isAfterNotAt: Bool = false, _ mapping: KeyMapping,
                        afterComplete: TableChange.CompletionHandler? = nil) {
    insertNewBindings(relativeTo: index, isAfterNotAt: isAfterNotAt, [mapping], afterComplete: afterComplete)
  }

  func removeBindings(at indexesToRemove: IndexSet) {
    Logger.log("Removing bindings (\(indexesToRemove.map{$0}))", level: .verbose)
    guard canModifyCurrentConfig else {
      Logger.log("Aborting: cannot modify current config!", level: .error)
      return
    }

    // If there is an active filter, the indexes reflect filtered rows.
    // Get the underlying IDs of the removed rows so that we can reliably update the unfiltered list of bindings.
    let idsToRemove = resolveBindingIDs(from: indexesToRemove, excluding: { !$0.canBeModified })

    if idsToRemove.isEmpty {
      Logger.log("Aborting remove operation: none of the rows can be modified")
      return
    }

    var remainingRowsUnfiltered: [InputBinding] = []
    var lastRemovedIndex = 0
    for (rowIndex, row) in bindingRowsAll.enumerated() {
      if let id = row.keyMapping.bindingID, idsToRemove.contains(id) {
        lastRemovedIndex = rowIndex
      } else {
        // be sure to include rows which do not have IDs
        remainingRowsUnfiltered.append(row)
      }
    }
    let tableChange = TableChange(.removeRows)
    tableChange.toRemove = indexesToRemove

    if TableChange.selectNextRowAfterDelete {
      // After removal, select the single row after the last one removed:
      let countRemoved = bindingRowsAll.count - remainingRowsUnfiltered.count
      if countRemoved < bindingRowsAll.count {
        let newSelectionIndex: Int = lastRemovedIndex - countRemoved + 1
        tableChange.newSelectedRows = IndexSet(integer: newSelectionIndex)
      }
    }

    doAction(remainingRowsUnfiltered, tableChange)
  }

  func updateBinding(at index: Int, to mapping: KeyMapping) {
    Logger.log("Updating binding at index \(index) to: \(mapping)", level: .verbose)
    guard canModifyCurrentConfig else {
      Logger.log("Aborting: cannot modify current config!", level: .error)
      return
    }

    guard let existingRow = getBindingRow(at: index), existingRow.canBeModified else {
      Logger.log("Cannot update binding at index \(index); aborting", level: .error)
      return
    }

    existingRow.keyMapping = mapping

    let tableChange = TableChange(.updateRows)

    tableChange.toUpdate = IndexSet(integer: index)

    var indexToUpdate: Int = index

    // The affected row will change index after the reload. Track it down before clearing the filter.
    if let unfilteredIndex = translateFilteredIndexToUnfilteredIndex(index) {
      indexToUpdate = unfilteredIndex
    }

    tableChange.newSelectedRows = IndexSet(integer: indexToUpdate)
    doAction(bindingRowsAll, tableChange)
  }

  // MARK: Various utility functions

  func isEditEnabledForBindingRow(_ rowIndex: Int) -> Bool {
    self.getBindingRow(at: rowIndex)?.canBeModified ?? false
  }

  func getClosestValidInsertIndex(from requestedIndex: Int, isAfterNotAt: Bool = false) -> Int {
    var insertIndex: Int
    if requestedIndex < 0 {
      // snap to very beginning
      insertIndex = 0
    } else if requestedIndex >= bindingRowsAll.count {
      // snap to very end
      insertIndex = bindingRowsAll.count
    } else {
      insertIndex = requestedIndex  // default to requested index
    }

    // If there is an active filter, convert the filtered index to unfiltered index
    if let unfilteredIndex = translateFilteredIndexToUnfilteredIndex(requestedIndex) {
      insertIndex = unfilteredIndex
    }

    // Adjust for insert cursor
    if isAfterNotAt {
      insertIndex = min(insertIndex + 1, bindingRowsAll.count)
    }

    // The "default" section is the only section which can be edited or changed.
    // If the insert cursor is outside the default section, then snap it to the nearest valid index.
    let ai = self.appInputConfig
    if insertIndex < ai.defaultSectionStartIndex {
      Logger.log("Insert index (\(insertIndex), origReq=\(requestedIndex)) is before the default section (\(ai.defaultSectionStartIndex) - \(ai.defaultSectionEndIndex)). Snapping it to index: \(ai.defaultSectionStartIndex)", level: .verbose)
      return ai.defaultSectionStartIndex
    }
    if insertIndex > ai.defaultSectionEndIndex {
      Logger.log("Insert index (\(insertIndex), origReq=\(requestedIndex)) is after the default section (\(ai.defaultSectionStartIndex) - \(ai.defaultSectionEndIndex)). Snapping it to index: \(ai.defaultSectionEndIndex)", level: .verbose)
      return ai.defaultSectionEndIndex
    }

    Logger.log("Returning insertIndex: \(insertIndex) from requestedIndex: \(requestedIndex)", level: .verbose)
    return insertIndex
  }

  // Finds the index into bindingRowsAll corresponding to the row with the same bindingID as the row with filteredIndex into bindingRowsFiltered.
  private func translateFilteredIndexToUnfilteredIndex(_ filteredIndex: Int) -> Int? {
    guard filteredIndex >= 0 else {
      return nil
    }
    guard isFiltered else {
      return filteredIndex
    }
    if filteredIndex == bindingRowsFiltered.count {
      let filteredRowAtIndex = bindingRowsFiltered[filteredIndex - 1]

      guard let unfilteredIndex = findUnfilteredIndexOfInputBinding(filteredRowAtIndex) else {
        return nil
      }
      return unfilteredIndex + 1
    }
    let filteredRowAtIndex = bindingRowsFiltered[filteredIndex]
    return findUnfilteredIndexOfInputBinding(filteredRowAtIndex)
  }

  private func findUnfilteredIndexOfInputBinding(_ row: InputBinding) -> Int? {
    if let bindingID = row.keyMapping.bindingID {
      for (unfilteredIndex, unfilteredRow) in bindingRowsAll.enumerated() {
        if unfilteredRow.keyMapping.bindingID == bindingID {
          Logger.log("Found matching bindingID \(bindingID) at unfiltered row index \(unfilteredIndex)", level: .verbose)
          return unfilteredIndex
        }
      }
    }
    Logger.log("Failed to find unfiltered row index for: \(row)", level: .error)
    return nil
  }

  static private func resolveBindingIDs(from rows: [InputBinding]) -> Set<Int> {
    return rows.reduce(into: Set<Int>(), { (ids, row) in
      if let bindingID = row.keyMapping.bindingID {
        ids.insert(bindingID)
      }
    })
  }

  private func resolveBindingIDs(from rowIndexes: IndexSet, excluding isExcluded: ((InputBinding) -> Bool)? = nil) -> Set<Int> {
    var idSet = Set<Int>()
    for rowIndex in rowIndexes {
      if let row = getBindingRow(at: rowIndex) {
        if let id = row.keyMapping.bindingID {
          if let isExcluded = isExcluded, isExcluded(row) {
          } else {
            idSet.insert(id)
          }
        } else {
          Logger.log("Cannot resolve row at index \(rowIndex): binding has no ID!", level: .error)
        }
      }
    }
    return idSet
  }

  // Inverse of previous function
  static private func resolveIndexesFromBindingIDs(_ bindingIDs: Set<Int>, in rows: [InputBinding]) -> IndexSet {
    var indexSet = IndexSet()
    for targetID in bindingIDs {
      for (rowIndex, row) in rows.enumerated() {
        guard let rowID = row.keyMapping.bindingID else {
          Logger.log("Cannot resolve row at index \(rowIndex): binding has no ID!", level: .error)
          continue
        }
        if rowID == targetID {
          indexSet.insert(rowIndex)
        }
      }
    }
    return indexSet
  }

  // Both params should be calculated based on UNFILTERED rows.
  // Let BindingTableStateManager deal with altering animations with a filter
  private func doAction(_ bindingRowsAllNew: [InputBinding], _ tableChange: TableChange) {
    let defaultSectionNew = bindingRowsAllNew.filter({ $0.origin == .confFile }).map({ $0.keyMapping })
    AppInputConfig.bindingTableStateManager.doAction(defaultSectionNew, tableChange)
  }

  private var canModifyCurrentConfig: Bool {
    if let currentConfigFile = self.inputConfigFile, !currentConfigFile.isReadOnly {
      return true
    }
    return false
  }

  // MARK: Filtering

  private var isFiltered: Bool {
    return !filterString.isEmpty
  }

  func filterBindings(_ searchString: String) {
    Logger.log("Updating Bindings UI filter to \"\(searchString)\"", level: .verbose)
    AppInputConfig.bindingTableStateManager.filterBindings(newFilterString: searchString)
  }

  private static func filter(bindingRowsAll: [InputBinding], by filterString: String) -> [InputBinding] {
    if filterString.isEmpty {
      return bindingRowsAll
    }
    return bindingRowsAll.filter {
      return $0.getKeyColumnDisplay(raw: true).localizedStandardContains(filterString)
      || $0.getActionColumnDisplay(raw: true).localizedStandardContains(filterString)
    }
  }

}