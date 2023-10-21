//
//  PlayerWindowPreviewImageBuilder.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-01.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let overlayAlpha: CGFloat = 0.6
fileprivate let opaqueControlAlpha: CGFloat = 1.0

fileprivate let scaleFactor: Int = 4
fileprivate let outputImgWidth: Int = 340 * scaleFactor
fileprivate let outputImgHeight: Int = outputImgWidth * 3 / 4  // Output image expected to be 4:3

fileprivate let titleBarHeight: Int = 24 * scaleFactor
fileprivate let menuBarHeight: Int = titleBarHeight
fileprivate let videoWidth: Int = 240 * scaleFactor
fileprivate let videoHeight: Int = videoWidth * 9 / 16
fileprivate let oscFullWidthHeight: Int = 35 * scaleFactor
fileprivate let oscFloatingHeight: Int = 37 * scaleFactor
fileprivate let oscFloatingWidth: Int = 140 * scaleFactor


fileprivate extension CGContext {
  // Decorator for state
  func withNewCGState<T>(_ closure: () throws -> T) rethrows -> T {
    saveGState()
    defer {
      restoreGState()
    }
    return try closure()
  }

  func drawRoundedRect(_ rect: NSRect, cornerRadius: CGFloat, fillColor: CGColor) {
    setFillColor(fillColor)
    // Clip its corners to round it:
    beginPath()
    addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    closePath()
    clip()
    fill([rect])
  }
}

class PlayerWindowPreviewImageBuilder {
  static var cgImageCache: [String: CGImage] = [:]

  let isLegacyWindow = Preference.bool(for: .useLegacyWindowedMode)
  let oscEnabled = Preference.bool(for: .enableOSC)
  let oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
  let topBarPlacement: Preference.PanelPlacement = Preference.enum(for: .topBarPlacement)
  let bottomBarPlacement: Preference.PanelPlacement = Preference.enum(for: .bottomBarPlacement)
  let appearance: NSAppearance

  lazy var hasTitleBar: Bool = {
    return !isLegacyWindow || PlayerWindowController.LayoutSpec.enableTitleBarForLegacyWindow  // No title bar for legacy window
  }()

  lazy var hasTopBar: Bool = {
    return hasTitleBar || (oscEnabled && oscPosition == .top)
  }()

  init(_ enclosingView: NSView) {
    self.appearance = enclosingView.iinaAppearance
  }

  fileprivate var iconColor: NSColor = {
    .textColor
  }()

  fileprivate lazy var desktopWallpaperColor: NSColor = {
    if appearance.isDark {
      return NSColor(red: 0x54 / 255, green: 0x55 / 255, blue: 0x54 / 255, alpha: 1.0)  // "stone"
    } else {
      return NSColor(red: 0x7A / 255, green: 0x7B / 255, blue: 0x80 / 255, alpha: 1.0)  // "space gray pro"
    }
//    NSColor(red: 0x68 / 255, green: 0x67 / 255, blue: 0xAF / 255, alpha: 1.0)  // "blue violet"
  }()

  func updateWindowPreviewImage() -> NSImage? {
    guard let videoViewImg = loadCGImage(named: "preview-videoview"),
          let titleBarButtonsImg = loadCGImage(named: "preview-titlebar-buttons") else {
      Logger.log("Cannot generate window preview image: failed to load asset(s)", level: .error)
      return nil
    }
    let titleBarHeight = hasTitleBar ? titleBarHeight : 0
    let roundedCornerRadius = isLegacyWindow ? 0 : CGFloat(10.0) * CGFloat(scaleFactor)

    var videoViewOffsetY: Int = 0
    if oscEnabled && oscPosition == .bottom && bottomBarPlacement == .outsideViewport {
      // add extra space for bottom bar
      videoViewOffsetY += oscFullWidthHeight
    }

    let oscOffsetY: Int
    let oscHeight: Int
    let oscAlpha: CGFloat
    if oscEnabled {

      switch oscPosition {

      case .top:
        let adjustment = oscFullWidthHeight / 8 // remove some space between controller & title bar
        oscHeight = oscFullWidthHeight - adjustment

        switch topBarPlacement {

        case .outsideViewport:
          oscAlpha = opaqueControlAlpha
          oscOffsetY = videoViewOffsetY + videoHeight

        case .insideViewport:
          oscAlpha = overlayAlpha
          oscOffsetY = videoViewOffsetY + videoHeight - oscHeight - titleBarHeight

        }  // end switch topBarPlacement

      case .bottom:
        oscHeight = oscFullWidthHeight

        switch bottomBarPlacement {
        case .outsideViewport:
          oscAlpha = opaqueControlAlpha
          oscOffsetY = videoViewOffsetY - oscFullWidthHeight
        case .insideViewport:
          oscAlpha = overlayAlpha
          oscOffsetY = videoViewOffsetY
        }  // end switch bottomBarPlacement

      case .floating:
        oscAlpha = overlayAlpha
        oscHeight = oscFloatingHeight
        oscOffsetY = videoViewOffsetY + (videoHeight / 2) - oscFloatingHeight

      }  // end switch oscPosition

    } else {
      // OSC disabled
      oscAlpha = overlayAlpha
      oscHeight = 0
      oscOffsetY = 0
    }

    var winHeight: Int = videoViewOffsetY + videoHeight
    if topBarPlacement == .outsideViewport {
      if oscEnabled && oscPosition == .top {
        winHeight += oscHeight
      }
      winHeight += titleBarHeight
    }
    let winOriginX: Int = (outputImgWidth - videoWidth) / 2
    let winOriginY: Int = (outputImgHeight - winHeight - menuBarHeight) / 2

    let winRect = NSRect(x: winOriginX, y: winOriginY, width: videoWidth, height: winHeight)

    let drawingCalls: (CGContext) -> Void = { [self] cgContext in
      // Draw desktop background color
      let bgColor = desktopWallpaperColor.cgColor
      cgContext.setFillColor(bgColor)
      cgContext.fill([CGRect(x: 0, y: 0, width: outputImgWidth, height: outputImgHeight)])

      // Draw menu bar
      let menuBarColor: CGColor = addAlpha(opaqueControlAlpha, to: NSColor.windowBackgroundColor)
      cgContext.setFillColor(menuBarColor)
      cgContext.fill([CGRect(x: 0, y: outputImgHeight - menuBarHeight, width: outputImgWidth, height: menuBarHeight)])

      if #available(macOS 11.0, *), let appleLogo = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) {
        let totalHeight = CGFloat(menuBarHeight)
        let padTotalV = totalHeight * 0.2
        let padTotalH = padTotalV * 3
        _ = drawPaddedIcon(appleLogo, in: cgContext, x: 0, y: CGFloat(outputImgHeight - menuBarHeight),
                           totalHeight: totalHeight, padTotalH: padTotalH, padTotalV: padTotalV)
      } else {
        // Fallback on earlier versions
      }


      // Start drawing window. Clip the corners to round it:
      cgContext.beginPath()
      cgContext.addPath(CGPath(roundedRect: winRect, cornerWidth: roundedCornerRadius, cornerHeight: roundedCornerRadius, transform: nil))
      cgContext.closePath()
      cgContext.clip()

      // draw video
      draw(image: videoViewImg, in: cgContext, x: winOriginX, y: winOriginY + videoViewOffsetY, width: videoWidth, height: videoHeight)

      // draw OSC
      if oscEnabled {

        let oscOffsetFromWindowOriginX: Int
        let oscWidth: Int
        if oscPosition == .floating {
          oscOffsetFromWindowOriginX = (videoWidth / 2) - (oscFloatingWidth / 2)
          oscWidth = oscFloatingWidth
        } else {
          oscOffsetFromWindowOriginX = 0
          oscWidth = videoWidth
        }

        let leftArrowImage = #imageLiteral(resourceName: "speedl")
        let playImage = #imageLiteral(resourceName: "play")
        let rightArrowImage = #imageLiteral(resourceName: "speed")

        let oscRect = NSRect(x: winOriginX + oscOffsetFromWindowOriginX, y: winOriginY + oscOffsetY, width: oscWidth, height: oscHeight)
        let oscPanelColor: CGColor = addAlpha(oscAlpha, to: NSColor.windowBackgroundColor)
        let iconHeight: CGFloat
        let iconGroupCenterY: CGFloat
        let spacingH: CGFloat
        var nextIconMinX: CGFloat

        if oscPosition == .floating {
          // Draw floating OSC panel
          cgContext.withNewCGState {
            cgContext.drawRoundedRect(oscRect, cornerRadius: roundedCornerRadius / 2, fillColor: oscPanelColor)
          }

          // Draw play controls
          iconHeight = CGFloat(oscHeight) * 0.44
          spacingH = iconHeight * 0.60
          let leftArrowWidth = CGFloat(iconHeight) * leftArrowImage.size.aspect
          let playWidth = CGFloat(iconHeight) * playImage.size.aspect
          let rightArrowWidth = CGFloat(iconHeight) * rightArrowImage.size.aspect
          let totalButtonWidth = leftArrowWidth + spacingH + playWidth + spacingH + rightArrowWidth

          iconGroupCenterY = oscRect.minY + (CGFloat(oscHeight) * 0.6)
          nextIconMinX = oscRect.minX + (oscRect.width * 0.5) - (totalButtonWidth * 0.5)

        } else {
          // Draw full-width OSC panel
          cgContext.setFillColor(oscPanelColor)
          cgContext.fill([oscRect])

          // Draw play controls
          iconHeight = CGFloat(oscHeight) * 0.5
          spacingH = iconHeight * 0.5

          iconGroupCenterY = oscRect.origin.y + (CGFloat(oscHeight) * 0.5)
          nextIconMinX = oscRect.origin.x
          nextIconMinX += spacingH
        }

        nextIconMinX += drawIconVCenter(leftArrowImage, in: cgContext, originX: nextIconMinX, centerY: iconGroupCenterY, iconHeight: iconHeight)
        nextIconMinX += spacingH
        nextIconMinX += drawIconVCenter(playImage, in: cgContext, originX: nextIconMinX, centerY: iconGroupCenterY, iconHeight: iconHeight)
        nextIconMinX += spacingH
        nextIconMinX += drawIconVCenter(rightArrowImage, in: cgContext, originX: nextIconMinX, centerY: iconGroupCenterY, iconHeight: iconHeight)
        nextIconMinX += spacingH

        if oscPosition == .floating {
          // Draw play position bar for "floating" OSC
          let playBarWidth = oscRect.width - spacingH - spacingH
          let playBarHeight = iconHeight * 0.2
          let playbarMinY = oscRect.minY + CGFloat(oscHeight) * 0.15
          let playBarRect = NSRect(x: Int(oscRect.minX + spacingH), y: Int(playbarMinY), width: Int(playBarWidth), height: Int(playBarHeight))
          cgContext.setFillColor(iconColor.cgColor)
          cgContext.fill([playBarRect])

        } else {
          let pillWidth = iconHeight // ~similar size
          // Subtract pill width and its spacing
          let playBarWidth = oscRect.maxX - nextIconMinX - spacingH - pillWidth - spacingH
          if playBarWidth < 0 {
            Logger.log("While drawing preview image: ran out of space while drawing OSC!", level: .error)
          } else {

            // Draw play position bar
            let playBarHeight = iconHeight * 0.25
            let playbarOriginY = iconGroupCenterY - (playBarHeight / 2)
            let playBarRect = NSRect(x: Int(nextIconMinX), y: Int(playbarOriginY), width: Int(playBarWidth), height: Int(playBarHeight))
            cgContext.setFillColor(iconColor.cgColor)
            cgContext.fill([playBarRect])

            // Draw little pill-shaped thing
            nextIconMinX += playBarWidth + spacingH
            let pillHeight = iconHeight * 0.55
            let pillOriginY = iconGroupCenterY - (pillHeight / 2)
            let pillRect = NSRect(x: Int(nextIconMinX), y: Int(pillOriginY), width: Int(pillWidth), height: Int(pillHeight))
            cgContext.withNewCGState {
              cgContext.drawRoundedRect(pillRect, cornerRadius: min(pillHeight * 0.5, roundedCornerRadius / 2), fillColor: iconColor.cgColor)
            }
          }
        }
      }

      if titleBarHeight > 0 {
        // Draw title bar
        var titleBarOffsetY: Int = videoViewOffsetY + videoHeight
        if topBarPlacement == .insideViewport {
          titleBarOffsetY -= titleBarHeight
        } else {  // outside
          if oscEnabled && oscPosition == .top {
            titleBarOffsetY += oscHeight
          }
        }

        let isTitleBarInside = topBarPlacement == .insideViewport
        let drawTitleBarBackground: Bool
        if isTitleBarInside || (oscEnabled && oscPosition == .top) {
          drawTitleBarBackground = true
        } else {
          drawTitleBarBackground = true
        }

        if drawTitleBarBackground {
          // Draw title bar background
          let titleBarAlpha: CGFloat = isTitleBarInside ? overlayAlpha : opaqueControlAlpha
          let titleBarColor: CGColor = addAlpha(titleBarAlpha, to: NSColor.windowBackgroundColor)
          cgContext.setFillColor(titleBarColor)
          cgContext.fill([CGRect(x: winOriginX, y: winOriginY + titleBarOffsetY, width: videoWidth, height: titleBarHeight)])
        }

        // Draw traffic light buttons
        let titleBarButtonsWidth = CGFloat(titleBarHeight) * (CGFloat(titleBarButtonsImg.width) / CGFloat(titleBarButtonsImg.height))
        draw(image: titleBarButtonsImg, in: cgContext, x: winOriginX, y: winOriginY + titleBarOffsetY, width: Int(titleBarButtonsWidth), height: titleBarHeight)
      }
    }  // drawingCalls

    let previewImage = drawImageInBitmapImageContext(width: outputImgWidth, height: outputImgHeight, drawingCalls: drawingCalls)?
      .roundCorners(withRadius: roundedCornerRadius)

    return previewImage
  }

  private func addAlpha(_ alpha: CGFloat, to color: NSColor) -> CGColor {
    color.withAlphaComponent(alpha).cgColor
  }

  private func loadCGImage(named name: String) -> CGImage? {
    if let cachedImage = PlayerWindowPreviewImageBuilder.cgImageCache[name] {
      return cachedImage
    }
    guard let image = NSImage(named: name) else {
      Logger.log("DrawImage: Failed to load image \(name.quoted)!", level: .error)
      return nil
    }
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      Logger.log("DrawImage: Failed to get CGImage for \(name.quoted)!", level: .error)
      return nil
    }
    PlayerWindowPreviewImageBuilder.cgImageCache[name] = cgImage
    return cgImage
  }

  /** Draws icon from left to right in the given context. The width of the icon is derived from `totalHeight` and the icon's aspect ratio.
  Returns the horizontal space which was used by the icon (including padding). */
  private func drawPaddedIcon(_ iconImage: NSImage, in cgContext: CGContext, x originX: CGFloat, y originY: CGFloat, totalHeight: CGFloat,
                              padTotalH: CGFloat? = nil, padTotalV: CGFloat? = nil,
                              padL: CGFloat? = nil, padR: CGFloat? = nil,
                              padT: CGFloat? = nil, padB: CGFloat? = nil) -> CGFloat {
    let padTotalHoriz: CGFloat = padTotalH ?? 0
    let padTotalVert: CGFloat = padTotalV ?? 0
    let padTop: CGFloat = padT ?? (padTotalVert / 2)
    let padBottom: CGFloat = padB ?? (padTotalVert / 2)
    let padLeft: CGFloat = padL ?? (padTotalHoriz / 2)
    let padRight: CGFloat = padR ?? (padTotalHoriz / 2)

    let iconHeight = totalHeight - padTop - padBottom
    let iconWidth = CGFloat(iconHeight) * iconImage.size.aspect

    drawIcon(iconImage, in: cgContext, originX: originX + padLeft, originY: originY + padBottom, width: iconWidth, height: iconHeight)
    return padRight + iconWidth
  }

  /** Draws icon from left to right in the given context. The width of the icon is derived from `iconHeight` and the icon's aspect ratio.
   Returns the width of the icon (not including padding). */
  private func drawIconVCenter(_ iconImage: NSImage, in cgContext: CGContext, originX: CGFloat, centerY: CGFloat, iconHeight: CGFloat) -> CGFloat {
    let originY = centerY - (iconHeight / 2)
    let iconWidth = CGFloat(iconHeight) * iconImage.size.aspect
    drawIcon(iconImage, in: cgContext, originX: originX, originY: originY, width: iconWidth, height: iconHeight)
    return iconWidth
  }

  private func drawIcon(_ iconImage: NSImage, in cgContext: CGContext, originX: CGFloat, originY: CGFloat, width: CGFloat, height: CGFloat) {
    let tintedImage: NSImage = iconImage.tinted(iconColor) // FIXME: apply alpha
    guard let cgImage = tintedImage.cgImage else {
      Logger.log("Cannot draw icon: failed to get tinted cgImage from NSImage \(iconImage.name()?.quoted ?? "nil")", level: .error)
      return
    }
    cgContext.draw(cgImage, in: CGRect(x: originX, y: originY, width: width, height: height))
  }

  private func draw(image cgImage: CGImage, in cgContext: CGContext,
                    withAlpha alpha: CGFloat = 1,
                    x: Int, y: Int, width widthOverride: Int? = nil, height heightOverride: Int? = nil) {
    let width = widthOverride ?? cgImage.width
    let height = heightOverride ?? cgImage.height
    cgContext.setAlpha(alpha)
    cgContext.draw(cgImage, in: CGRect(x: x, y: y, width: width, height: height))
    cgContext.setAlpha(1)
  }

  private func drawImageInBitmapImageContext(width: Int, height: Int, drawingCalls: (CGContext) -> Void) -> NSImage? {

    guard let compositeImageRep = makeNewImgRep(width: width, height: height) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSBitmapImageRep!", level: .error)
      return nil
    }

    guard let context = NSGraphicsContext(bitmapImageRep: compositeImageRep) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSGraphicsContext!", level: .error)
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cgContext = context.cgContext

    appearance.applyAppearanceFor {
      drawingCalls(cgContext)
    }

    defer {
      NSGraphicsContext.restoreGraphicsState()
    }

    let outputImage = NSImage(size: CGSize(width: width, height: height))
    // Create the CGImage from the contents of the bitmap context.
    outputImage.addRepresentation(compositeImageRep)

    return outputImage
  }

  // Creates RGB image with alpha channel
  private func makeNewImgRep(width: Int, height: Int) -> NSBitmapImageRep? {
    return NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: NSColorSpaceName.calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
  }
}
