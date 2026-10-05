//
//  MetalVideoLayer.swift
//  iina
//
//  Created by Matt Svoboda on 2025-03-25.
//  Copyright © 2025 lhc. All rights reserved.
//

class MetalVideoLayer: CAMetalLayer {

  override init() {
    super.init()

    initialize()
  }

  // necessary for when the layer containing window changes the screen
  override init(layer: Any) {
    super.init()
    initialize()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func initialize() {
    device = MTLCreateSystemDefaultDevice()!
    framebufferOnly = true
    displaySyncEnabled = false
    pixelFormat = .rgba16Float
    backgroundColor = NSColor.black.cgColor
  }

  /// Capture the next rendered frame as an `NSImage`. Forces a redraw so this works while paused.
  func captureSnapshot() async -> NSImage? {
    // TODO: implement this
    return nil
  }
}
