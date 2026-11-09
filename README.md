# beats-me

Player for mixtapes made in `../analyze-this` and for any local music.
Playback, tempo analysis and the now-playing UI live in `../shared_core`.

    flutter pub get && flutter test && flutter run -d windows

## Deploy to an Android phone (Wi-Fi)

One-time phone setup: Settings › About phone › tap "Build number" 7 times, then
Developer options › turn on **Wireless debugging** (phone and PC on the same Wi-Fi).

    deploy-android            # connect, build if changed, install, launch
    deploy-android -Logs      # ...then stream the app's logcat
    deploy-android -Attach    # flutter run --release (logs + hot restart)
    deploy-android -Force     # rebuild even if nothing changed
    deploy-android -Pair      # pair with a new phone
    deploy-android -Device <serial>

The script finds the phone by itself: it tries the last-used address, then mDNS
discovery, and asks you to pair only if both fail. If more than one device is
connected, it asks which one to use. It rebuilds the arm64 release APK only when
`lib`, `android`, the pubspec files or `../shared_core` changed, and it increments
the build number on each build. Its state is kept in `.deploy\`, which is gitignored.

## Features

- **Own it?**: search the desktop-owned album catalogue offline by artist and album
  tokens, independently of the phone's music library. Send the metadata snapshot
  from analyze-this over **paired Wi-Fi push** while beats-me is receiving, or
  by **USB** (`albums.json` in the phone inbox); resume the app or use its USB
  inbox check to import it. No catalogue pull or audio transfer is involved.
  Snapshots persist in app storage; malformed or failed syncs keep the previous
  snapshot and report an error. USB files are claimed by a unique staging rename
  and only consumed after saving; failed staging files remain for retry, without
  deleting a newer USB delivery.
  The displayed **snapshot time** is when the desktop generated it, not when the
  phone received it. Counts show `?` for unknown totals; these are not claimed
  complete. Explicit incomplete flags can indicate missing discs even when the
  known track counts match. No match means only "not in the synced catalogue",
  never authoritative evidence that you do not own an album.
- **Receiving mixes**: Wi-Fi push, pull or USB. Once a PC is paired, mixes are received
  automatically while the app is open (setting "Receive mixes from PC while beats-me
  is open"). Songs already on the phone from another mix are reused instead of
  downloaded again.
- **Mixes list**: search, sort (recent, name, last played, size), size on disk, free
  space; refreshes after imports and stays fast thanks to a summary cache.
- **Damaged songs**: mixes with songs the PC flagged as damaged show a badge and a
  count; a mix's menu › "Check songs for damage" re-checks the files on the phone.
  Replace them on the PC and resend.
- **Ratings & favourites**: rate from Now Playing or a song's menu.
- **Play journal**: plays and ratings are logged and synced back to analyze-this over
  Wi-Fi or USB, then trimmed once the PC acknowledges them.
- **Keep screen on** while Now Playing is visible and playing (playback settings).
- **Song settings from the PC**: trimmed starts/ends are honoured, and volume is
  levelled from the PC's loudness measurement (playback settings › Level loudness).
- **Cues & notes**: the instructor card on Now Playing shows the song's cue and the
  activity notes, and can speak the cue as the song starts.
- **Activity change alerts**: before each activity or segment change: a spoken
  heads-up 10 s before, beeps at 3-2-1, a full-screen flash and a vibration on the
  change. Pick any of voice / beep / flash / vibrate in playback settings.
- **Class mode**: the full-screen button on Now Playing gives a dark, large-type view
  for the bike: activity, RPM and gear, a big countdown to the next change, class
  elapsed/remaining and what's next. The screen stays on.
