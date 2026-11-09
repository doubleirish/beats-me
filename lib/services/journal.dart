import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone's play/rating journal (`<app support>/journal.jsonl`), synced to
/// analyze-this over Wi-Fi or USB. On Android it is mirrored to
/// [phoneJournal] when storage permission allows, so adb can read it.
class AppJournal {
  AppJournal._();

  static PlayJournal? _journal;
  static Future<PlayJournal>? _opening;
  static String? _device;

  /// Points the journal at [journal] (tests); skips the app-support lookup.
  static void useJournal(PlayJournal journal, {String device = 'test'}) {
    _journal = journal;
    _opening = null;
    _device = device;
  }

  /// The journal, with the mirror refreshed to match the storage permission.
  static Future<PlayJournal> get journal async {
    final j = _journal ?? await (_opening ??= _open());
    j.mirror = await _mirror();
    return j;
  }

  static Future<PlayJournal> _open() async {
    final dir = await getApplicationSupportDirectory();
    return _journal = PlayJournal(File(p.join(dir.path, 'journal.jsonl')));
  }

  static Future<File?> _mirror() async {
    if (!Platform.isAndroid) return null;
    try {
      if (!await Permission.manageExternalStorage.isGranted) return null;
      return File(phoneJournal);
    } catch (_) {
      return null;
    }
  }

  /// Same id as MixtapeController uses for pairing and inventories.
  static Future<String> deviceId() async {
    if (_device != null) return _device!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = newMixtapeId();
      await prefs.setString('device_id', id);
    }
    return _device = id;
  }
}

/// Trims [j] up to the seq acknowledged in [ackFile] (dropped over USB by
/// analyze-this), then deletes the ack. An ack beyond the journal's last seq
/// (corrupt) only trims up to that seq. Returns the seq trimmed to, or null
/// when there was no usable ack.
Future<int?> applyJournalAck(PlayJournal j, File ackFile) async {
  try {
    if (!await ackFile.exists()) return null;
    final upTo = parseAck(await ackFile.readAsString());
    int? trimmed;
    if (upTo != null) {
      final last = await j.lastSeq;
      trimmed = upTo < last ? upTo : last;
      await j.trimTo(trimmed);
    }
    await ackFile.delete();
    return trimmed;
  } catch (_) {
    return null;
  }
}

/// Applies a USB journal ack, if any (Android with storage permission only).
Future<void> applyUsbJournalAck() async {
  if (!Platform.isAndroid) return;
  try {
    if (!await Permission.manageExternalStorage.isGranted) return;
    await applyJournalAck(await AppJournal.journal, File(phoneJournalAck));
  } catch (_) {}
}

/// Records a finished play of [path] (with its `.meta.json` details).
Future<void> logPlay(String path, double listened, bool completed) async {
  try {
    final e = await JournalEntry.playOf(path,
        device: await AppJournal.deviceId(), listened: listened, done: completed);
    await (await AppJournal.journal).append(e);
  } catch (_) {}
}

/// Records a rating/favourite change for [path].
Future<void> logRating(String path, int rating, bool fav) async {
  try {
    final e = await JournalEntry.rateOf(path,
        device: await AppJournal.deviceId(), rating: rating, fav: fav);
    await (await AppJournal.journal).append(e);
  } catch (_) {}
}
