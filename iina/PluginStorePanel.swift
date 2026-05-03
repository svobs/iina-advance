//
//  PluginStore.swift
//  iina
//
//  Created by Hechen Li on 2026-04-18.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let defaultPlugins = [
  ["url": "iina/plugin-online-media", "id": "io.iina.ytdl"],
  ["url": "iina/plugin-userscript", "id": "io.iina.user-script"],
  ["url": "iina/plugin-opensub", "id": "io.iina.opensub"],
]

class PluginStorePanel: NSWindow {
  let l10n: SettingsLocalization.Context

  init(l10n: SettingsLocalization.Context) {
    self.l10n = l10n

    let style: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView]
    let rect = NSRect(x: 0, y: 0, width: 600, height: 400)
    super.init(contentRect: rect, styleMask: style, backing: .buffered, defer: false)

    guard let contentView = contentView else {
      Logger.log("Content view is nil in plugin details window", level: .error)
      return
    }

    let titleLabel = NSTextField(labelWithString: l10n.localized(.text_PleaseEnterTheFullURL))
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(titleLabel)
    titleLabel.padding(.top(16), .horizontal(16))

    let urlField = NSTextField()
    urlField.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(urlField)
    urlField.padding(.horizontal(16)).spacing(to: titleLabel, .top(8))
  }
}
