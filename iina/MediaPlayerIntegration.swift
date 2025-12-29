//
//  NowPlayingInfoManager.swift
//  iina
//
//  Created by Matt Svoboda on 2024-12-03.
//  Copyright © 2024 lhc. All rights reserved.
//
import Foundation
import MediaPlayer

final class MediaPlayerIntegration {
  @MainActor
  static let shared = MediaPlayerIntegration()

  private var enabled = false
  private let remoteCommand = MPRemoteCommandCenter.shared()
  private var lastActivePlayer: PlayerCore? = nil

  @MainActor
  func update() {
    guard !AppDelegate.shared.isTerminating else { return }
    let newEnablement = Preference.bool(for: .useMediaKeys)
    updateEnablement(to: newEnablement)
    guard newEnablement else { return }
    updateNowPlayingInfo()
  }

  @MainActor
  private func updateEnablement(to newEnablement: Bool) {
    let didChange = enabled != newEnablement
    guard didChange else { return }
    enabled = newEnablement

    if newEnablement {
      attachRemoteCommands()
    } else {
      detachAllCommands()
    }
  }

  @MainActor
  func shutdown() {
    updateEnablement(to: false)
  }

  private func buildCmdHandler(forKey normalizedMpvKey: String,
                               fallbackAction: @escaping (PlayerCore, MPRemoteCommandEvent) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    { [self] event in
      guard let player = lastActivePlayer else { return .commandFailed }
      player.pwc.executeActionForKey(normalizedMpvKey: normalizedMpvKey, fallbackAction: { player in fallbackAction(player, event) })
      updateCommandEnablements(for: player)
      return .success
    }
  }

  private func buildCmdHandler(_ commandFunc: @escaping (PlayerCore, MPRemoteCommandEvent) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    { [self] event in
      guard let player = lastActivePlayer else { return .commandFailed }
      commandFunc(player, event)
      updateCommandEnablements(for: player)
      return .success
    }
  }

  private func attachRemoteCommands() {
    Logger.log.trace("Attaching MediaPlayer remote commands")
    remoteCommand.playCommand.addTarget(handler: buildCmdHandler(forKey: "PLAY", fallbackAction: { p, _ in p.resume() }))
    remoteCommand.pauseCommand.addTarget(handler: buildCmdHandler(forKey: "PAUSE", fallbackAction: { p, _ in p.pause() }))
    remoteCommand.togglePlayPauseCommand.addTarget(handler: buildCmdHandler(forKey: "PLAYPAUSE", fallbackAction: { p, _ in p.togglePause() }))
    remoteCommand.stopCommand.addTarget(handler: buildCmdHandler(forKey: "STOP", fallbackAction: { p, _ in p.stop() }))
    remoteCommand.nextTrackCommand.addTarget(handler: buildCmdHandler(forKey: "NEXT", fallbackAction: { p, _ in p.navigateInPlaylist(nextMedia: true) }))
    remoteCommand.previousTrackCommand.addTarget(handler: buildCmdHandler(forKey: "PREV", fallbackAction: { p, _ in p.navigateInPlaylist(nextMedia: false) }))
    remoteCommand.changeRepeatModeCommand.addTarget(handler: buildCmdHandler{ player, _ in player.nextLoopMode() })
    remoteCommand.changeShuffleModeCommand.isEnabled = false
    // remoteCommand.changeShuffleModeCommand.addTarget {})
    remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
    remoteCommand.changePlaybackRateCommand.addTarget(handler: buildCmdHandler{ player, event in
      player.setSpeed(Double((event as! MPChangePlaybackRateCommandEvent).playbackRate))
    })
    remoteCommand.skipForwardCommand.preferredIntervals = [15]
    remoteCommand.skipForwardCommand.addTarget(handler: buildCmdHandler(forKey: "GO_FORWARD", fallbackAction: { player, event in
      player.seek(relativeSecond: (event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
    }))
    remoteCommand.skipBackwardCommand.preferredIntervals = [15]
    remoteCommand.skipBackwardCommand.addTarget(handler: buildCmdHandler(forKey: "GO_BACK", fallbackAction: { player, event in
      player.seek(relativeSecond: -(event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
    }))
    remoteCommand.changePlaybackPositionCommand.addTarget(handler: buildCmdHandler{ player, event in
      player.seek(absoluteSecond: (event as! MPChangePlaybackPositionCommandEvent).positionTime)
    })
  }

  private func detachAllCommands() {
    Logger.log.trace("Detaching MediaPlayer remote commands")
    remoteCommand.playCommand.removeTarget(nil)
    remoteCommand.pauseCommand.removeTarget(nil)
    remoteCommand.togglePlayPauseCommand.removeTarget(nil)
    remoteCommand.stopCommand.removeTarget(nil)
    remoteCommand.nextTrackCommand.removeTarget(nil)
    remoteCommand.previousTrackCommand.removeTarget(nil)
    remoteCommand.changeRepeatModeCommand.removeTarget(nil)
//    remoteCommand.changeShuffleModeCommand.removeTarget(nil)
    remoteCommand.changePlaybackRateCommand.removeTarget(nil)
    remoteCommand.skipForwardCommand.removeTarget(nil)
    remoteCommand.skipBackwardCommand.removeTarget(nil)
    remoteCommand.changePlaybackPositionCommand.removeTarget(nil)
  }


  /// Update the information shown by macOS in `Now Playing`.
  ///
  /// The macOS [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac)
  /// contains a `Now Playing` module. This module can also be configured to be directly accessible from the menu bar.
  /// `Now Playing` displays the title of the media currently  playing and other information about the state of playback. It also can be
  /// used to control playback. IINA is fully integrated with the macOS `Now Playing` module.
  ///
  /// - Note: See [Becoming a Now Playable App](https://developer.apple.com/documentation/mediaplayer/becoming_a_now_playable_app)
  ///         and [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
  ///         for more information.
  ///
  /// This method must be run on the main thread because it references `PlayerManager.shared.lastActivePlayer`.
  @MainActor
  private func updateNowPlayingInfo() {
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [String: Any]()

    guard let activePlayer = PlayerManager.shared.lastActivePlayer, !activePlayer.isStopping else {
      center.playbackState = .unknown
      center.nowPlayingInfo = nil
      updateEnablement(to: false)
      return
    }
    self.lastActivePlayer = activePlayer

    if activePlayer.info.currentMediaAudioStatus.isAudio {
      info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
      let (title, album, artist) = activePlayer.getMusicMetadata()
      info[MPMediaItemPropertyTitle] = title
      info[MPMediaItemPropertyAlbumTitle] = album
      info[MPMediaItemPropertyArtist] = artist
    } else {
      info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
      info[MPMediaItemPropertyTitle] = activePlayer.getMediaTitle(withExtension: false)
      info[MPMediaItemPropertyAlbumTitle] = ""
      info[MPMediaItemPropertyArtist] = ""
    }

    let artwork: MPMediaItemArtwork?
    if activePlayer.info.isVideoTrackSelected, (activePlayer.info.currentPlayback?.thumbnails?.thumbnails.count ?? 0) > 0 {
      artwork = MPMediaItemArtwork(boundsSize: activePlayer.videoGeo.videoSizeCAR, requestHandler: { displaySize in
        // TODO: figure out a way to use screenshot-raw from mpv instead!
        // Use thumbnail if available
        if let currentPosition = activePlayer.info.playbackPositionSec, activePlayer.info.isVideoTrackSelected,
           let thumbImg = activePlayer.info.currentPlayback?.thumbnails?.getThumbnail(forSecond: currentPosition)?.image {
          // Crop to aspect ratio of requested size, rather than stretching/squeezing. Then resize
          let cropRect = thumbImg.size().getCropRect(withAspect: displaySize.aspect)
          if let previewImg = thumbImg.cropping(to: cropRect)?.resized(newWidth: displaySize.widthInt, newHeight: displaySize.heightInt).toNSImage() {
            return previewImg
          }
        }
        // Default album art
        return #imageLiteral(resourceName: "default-album-art").resized(newWidth: displaySize.widthInt, newHeight: displaySize.heightInt)
      })
    } else {
      artwork = nil
    }
    info[MPMediaItemPropertyArtwork] = artwork

    let duration = activePlayer.info.playbackDurationSec ?? 0
    let time = activePlayer.info.playbackPositionSec ?? 0
    let speed = activePlayer.info.playSpeed

    info[MPMediaItemPropertyPlaybackDuration] = duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
    info[MPNowPlayingInfoPropertyPlaybackRate] = speed
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1
    info[MPNowPlayingInfoPropertyAssetURL] = activePlayer.info.currentPlayback?.url

    center.nowPlayingInfo = info

    if activePlayer.info.isFileLoaded {
      center.playbackState = activePlayer.info.isPaused ? .paused : .playing
    } else {
      center.playbackState = .unknown
    }

    updateCommandEnablements(for: activePlayer)
  }

  private func updateCommandEnablements(for player: PlayerCore) {
    remoteCommand.skipBackwardCommand.isEnabled = player.canSkipBackward
    remoteCommand.skipForwardCommand.isEnabled = player.canSkipForward
    remoteCommand.previousTrackCommand.isEnabled = player.canPlayPrevTrack
    remoteCommand.nextTrackCommand.isEnabled = player.canPlayNextTrack
  }
}
