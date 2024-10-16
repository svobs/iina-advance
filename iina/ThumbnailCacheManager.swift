//
//  ThumbnailCacheManager.swift
//  iina
//
//  Created by lhc on 28/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class ThumbnailCacheManager {

  static var shared = ThumbnailCacheManager()

  var isJobRunning = false
  var needsRefresh = true

  private var cachedContents: [URL]?

  private func cacheFolderContents() -> [URL]? {
    if needsRefresh {
      ThumbnailCache.log.verbose("Refreshing cached thumbnails index")
      var updatedCache: [URL] = []
      if let thumbWidthDirs = try? FileManager.default.contentsOfDirectory(at: Utility.thumbnailCacheURL,
                                                                    includingPropertiesForKeys: [.contentAccessDateKey],
                                                                           options:
                                                                            [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
        for thumbWidthDir in thumbWidthDirs {
          if let dirThumbFiles = try? FileManager.default.contentsOfDirectory(at: thumbWidthDir,
                                                                               includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                                                                              options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            updatedCache.append(contentsOf: dirThumbFiles)
          }
        }
      }
      cachedContents = updatedCache
      needsRefresh = false
    }
    return cachedContents
  }

  func getCacheSize() -> Int {
    return cacheFolderContents()?.reduce(0 as Int) { totalSize, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      return totalSize + size
    } ?? 0
  }

  func clearOldCache() {
    guard !isJobRunning else { return }
    isJobRunning = true

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize)
    // if full, delete 50% of max cache
    let cacheToDelete = maxCacheSize * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue / 2

    ThumbnailCache.log.verbose("Looking for \(cacheToDelete) byte to delete from thumbnail cache")

    // sort by access date
    guard let contents = cacheFolderContents()?.sorted(by: { url1, url2 in
      let date1 = (try? url1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
      let date2 = (try? url2.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
      return date1.compare(date2) == .orderedAscending
    }) else { return }

    // delete old cache
    var clearedCacheSize = 0
    for url in contents {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      if clearedCacheSize < cacheToDelete {
        try? FileManager.default.removeItem(at: url)
        clearedCacheSize += size
      } else {
        break
      }
    }
    ThumbnailCache.log.verbose("Cleared \(clearedCacheSize) bytes from thumbnail cache")
  }

}
