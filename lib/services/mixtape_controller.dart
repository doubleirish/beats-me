import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'album_catalog_store.dart';
import 'auto_receive.dart';
import 'journal.dart' show AppJournal, applyUsbJournalAck;
import 'system_channel.dart';

/// A PC allowed to push mixtapes to this phone.
class TrustedPc {
  TrustedPc(this.id, this.name, this.token);
  final String id, name, token;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'token': token};
}

/// Imports mixtapes from analyze-this by every method. Packages are routed
/// by their own label, so any method's package is accepted.
class MixtapeController extends ChangeNotifier {
  MixtapeController(this.app) {
    albumCatalog.addListener(() {
      final error = albumCatalog.error;
      if (error != null && error != _lastCatalogError) say(error);
      _lastCatalogError = error;
    });
  }
  final AppState app;
  final AlbumCatalogStore albumCatalog = AlbumCatalogStore();
  String? _lastCatalogError;

  final List<String> log = [];
  String? busy;
  double? progress;
  bool _cancel = false;

  /// Shows "Allow this PC?" to the user; set by the UI.
  Future<bool> Function(PairRequest req)? confirmPair;

  /// Brings the Import screen to the front (e.g. after a QR link or file).
  void Function()? showImportScreen;

  /// Short notices for when the Import screen isn't open.
  void Function(String message)? notify;

  String deviceId = '';
  String deviceName = 'phone';
  final List<TrustedPc> trusted = [];

  PushReceiver? receiver;
  DiscoveryResponder? _responder;
  Timer? _stall;
  List<String> addresses = [];

  /// The Import screen keeps the receiver open (and allows pairing).
  bool _held = false;
  bool? _autoSetting;
  bool _ready = false;
  bool _foreground = true;
  Future<void>? _starting;
  Timer? _idleStop;

  SyncdirWatcher? watcher;
  String? syncRoot;

  PullClient? pullClient;
  String? pullFrom;
  List<RemoteMixtape> remote = [];

  bool get receiving => receiver?.running ?? false;
  bool get watching => watcher?.running ?? false;

  /// "Receive mixes from PC while beats-me is open". Unless the user chose,
  /// it's on once a PC is trusted.
  bool get autoReceive => AutoReceive.enabled(setting: _autoSetting, trustedCount: trusted.length);

  /// Receiving by itself, without the Import screen open.
  bool get autoReceiving => receiving && !_held;

  Future<void> setAutoReceive(bool on) async {
    _autoSetting = on;
    await (await SharedPreferences.getInstance()).setBool(AutoReceive.prefKey, on);
    notifyListeners();
    await _reconcile();
  }

  void say(String m) {
    log.insert(0, m);
    if (log.length > 60) log.removeLast();
    notifyListeners();
  }

  void cancel() => _cancel = true;

  // ------------------------------------------------------------- lifecycle

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = newMixtapeId();
      await prefs.setString('device_id', id);
    }
    deviceId = id;
    deviceName = await SystemChannel.deviceName();
    trusted.clear();
    try {
      for (final j in jsonDecode(prefs.getString('trusted_pcs') ?? '[]') as List) {
        final m = (j as Map).cast<String, dynamic>();
        trusted.add(TrustedPc('${m['id']}', '${m['name']}', '${m['token']}'));
      }
    } catch (_) {}
    _autoSetting = prefs.getBool(AutoReceive.prefKey);
    final ls = WidgetsBinding.instance.lifecycleState;
    _foreground = ls != AppLifecycleState.paused && ls != AppLifecycleState.detached;
    _ready = true;
    unawaited(_reconcile());
    final first = await SystemChannel.listen(handleIntent);
    if (first != null) await handleIntent(first);
  }

  /// Called when the app comes back to the front: starts auto-receive and
  /// picks up USB sends.
  Future<void> onResume() async {
    _foreground = true;
    _idleStop?.cancel();
    await _reconcile();
    if (!Platform.isAndroid || busy != null) return;
    if (!await Permission.manageExternalStorage.isGranted) return;
    if (!await Directory(phoneInbox).exists()) return;
    await scanInbox(quiet: true);
  }

  /// Called when the app goes to the background: stops auto-receive unless a
  /// transfer is running (the transfer service keeps that one alive).
  Future<void> onPause() async {
    _foreground = false;
    await _reconcile();
  }

  /// Starts or stops the receiver to match the auto-receive setting, the
  /// Import screen and whether the app is in front.
  Future<void> _reconcile({bool allowStart = true}) async {
    if (!_ready || _starting != null) return;
    final action = AutoReceive.decide(
      setting: _autoSetting,
      trustedCount: trusted.length,
      foreground: _foreground,
      held: _held,
      receiving: receiving,
      transferring: busy != null,
    );
    if (action == ReceiveAction.start && allowStart) await _startReceiving(auto: true);
    if (action == ReceiveAction.stop) await stopReceiving();
  }

  /// After a transfer in the background, stops auto-receive once the PC has
  /// had its reply.
  void _afterTransfer() {
    if (_foreground) return;
    _idleStop?.cancel();
    _idleStop = Timer(const Duration(seconds: 5), () => unawaited(_reconcile(allowStart: false)));
  }

  Future<void> handleIntent(Map<String, String> m) async {
    switch (m['type']) {
      case 'inbox':
        showImportScreen?.call();
        await scanInbox();
      case 'link':
        final link = PullLink.parse(m['value'] ?? '');
        if (link == null) {
          say('That link isn’t a beats-me QR code.');
          return;
        }
        showImportScreen?.call();
        await connectPull(link);
      case 'receiving':
        showImportScreen?.call();
        busy = 'Opening ${m['value']}…';
        notifyListeners();
      case 'file':
        busy = null;
        showImportScreen?.call();
        await importFile(File(m['value']!));
      case 'error':
        busy = null;
        say(m['value'] ?? 'Couldn’t open that.');
    }
  }

  Future<void> _saveTrusted() async =>
      (await SharedPreferences.getInstance()).setString('trusted_pcs', jsonEncode([for (final t in trusted) t.toJson()]));

  Future<void> forgetPc(String id) async {
    trusted.removeWhere((t) => t.id == id);
    await _saveTrusted();
    notifyListeners();
    await _reconcile();
  }

  // --------------------------------------------------------------- helpers

  Future<MixtapeImporter> _importer() async {
    await app.ensureStoragePermission();
    final root = await app.mixtapeRoot();
    await root.create(recursive: true);
    return MixtapeImporter(root);
  }

  Future<Directory> _staging(String label) async => Directory(
      p.join((await getTemporaryDirectory()).path, 'mixtape_staging', label));

  void _progress(int done, int total, String what, [String verb = 'Installing']) {
    progress = total == 0 ? null : done / total;
    busy = what == 'done' ? 'Finishing…' : '$verb $what';
    notifyListeners();
  }

  /// Keeps the phone (CPU + Wi-Fi) awake while the Import screen is
  /// receiving or anything is transferring. Auto-receive alone doesn't need
  /// it: it only runs while the app is in front.
  bool _serviceOn = false;
  void _updateService() {
    final want = (receiving && _held) || busy != null;
    if (want == _serviceOn) return;
    _serviceOn = want;
    if (want) {
      unawaited(SystemChannel.startTransferService(
          busy == null ? 'Ready to receive mixtapes from your PC' : 'Importing a mixtape'));
    } else {
      unawaited(SystemChannel.stopTransferService());
    }
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _updateService();
  }

  Future<T?> _run<T>(String label, Future<T> Function() job) async {
    if (busy != null && !busy!.startsWith('Opening')) return null;
    busy = label;
    progress = null;
    _cancel = false;
    notifyListeners();
    try {
      return await job();
    } on TransferException catch (e) {
      say(e.kind == TransferError.cancelled ? 'Cancelled.' : e.message);
      return null;
    } on ImportException catch (e) {
      say(e.message);
      return null;
    } catch (e) {
      say('Failed: $e');
      return null;
    } finally {
      busy = null;
      progress = null;
      notifyListeners();
      _afterTransfer();
    }
  }

  Future<void> _installed(ImportResult r, {bool apply = true}) async {
    if (apply) await app.applyImported(r);
    await writeInventory();
    await app.mixesChanged();
    final msg = 'Imported "${r.manifest.name}": ${r.paths.length} songs '
        '(${r.copied} new, ${r.reused} already here'
        '${r.reusedOther > 0 ? ', ${r.reusedOther} reused from other mixes' : ''})'
        '${r.errors.isEmpty ? '' : ', ${r.errors.length} problems: ${r.errors.first}'}';
    say(msg);
    notify?.call(msg);
  }

  /// Where [writeInventory] writes; tests point it at a temp file (it is
  /// only written on Android otherwise).
  @visibleForTesting
  File? inventoryFile;

  /// Copies the import ledger where the PC can read it over USB (adb), so
  /// USB sends only copy songs the phone doesn't already have.
  Future<void> writeInventory() async {
    final out = inventoryFile ?? (Platform.isAndroid ? File(phoneInventory) : null);
    if (out == null) return;
    try {
      final imp = MixtapeImporter(await app.mixtapeRoot());
      await out.parent.create(recursive: true);
      await writeStringAtomic(out, jsonEncode(await imp.ledger()));
    } catch (_) {}
  }

  // ------------------------------------------------------- Wi-Fi (push)

  /// Starts listening for the PC from the Import screen: answers discovery and
  /// accepts pushes from trusted PCs or the code shown on screen, and lets new
  /// PCs ask to be allowed. Keeps running until [releaseReceiving].
  Future<void> startReceiving() async {
    _held = true;
    if (_starting != null) await _starting;
    if (receiving) {
      receiver!.acceptToken = true;
      _updateService();
      addresses = await lanAddresses();
      notifyListeners();
      return;
    }
    await _startReceiving(auto: false);
  }

  /// The Import screen closed: keeps receiving only for auto-receive or a
  /// running transfer. Doesn't notify synchronously (called from dispose).
  Future<void> releaseReceiving() async {
    _held = false;
    receiver?.acceptToken = false;
    _updateService();
    await _reconcile(allowStart: false);
  }

  Future<void> _startReceiving({required bool auto}) async {
    if (_starting != null) return _starting;
    final f = _start(auto);
    _starting = f;
    try {
      await f;
    } finally {
      _starting = null;
    }
    receiver?.acceptToken = _held;
    // The app may have gone to the background or the Import screen closed
    // while starting.
    await _reconcile(allowStart: false);
  }

  Future<void> _start(bool auto) async {
    final MixtapeImporter imp;
    try {
      if (auto) {
        // Auto-receive never asks for permissions; the Import screen does.
        if (Platform.isAndroid && !await Permission.manageExternalStorage.isGranted) return;
        final root = await app.mixtapeRoot();
        await root.create(recursive: true);
        imp = MixtapeImporter(root);
      } else {
        imp = await _importer();
      }
    } catch (e) {
      say('Can’t open the music folder: $e');
      return;
    }
    var served = 0;
    final r = PushReceiver(
      importer: imp,
      staging: await _staging(Transport.push),
      deviceName: deviceName,
      deviceId: deviceId,
      isTrusted: (tok) => trusted.any((t) => t.token == tok),
      acceptToken: _held,
      onPair: _onPair,
      onCatalog: (catalog) async {
        await albumCatalog.save(catalog);
        final msg = 'Synced desktop catalogue: ${catalog.albums.length} albums (metadata only).';
        say(msg);
        notify?.call(msg);
        _afterTransfer();
      },
      journal: (since) async {
        final list = await (await AppJournal.journal).since(since);
        if (list.isNotEmpty && list.last.seq > served) served = list.last.seq;
        return list;
      },
      // Never trim past what this PC was actually sent.
      ackJournal: (upTo) async => (await AppJournal.journal).trimTo(upTo < served ? upTo : served),
      freeBytes: () async => SystemChannel.freeBytes(imp.destRoot.path),
      onProgress: (m) {
        // A send starting while the Import screen is closed: show it there.
        if (busy == null) showImportScreen?.call();
        busy = m;
        notifyListeners();
      },
      onFileProgress: (d, t, what) {
        _stall?.cancel();
        _stall = Timer(const Duration(seconds: 90), () {
          if (busy != null && busy!.startsWith('Receiving')) {
            busy = null;
            progress = null;
            say('The PC stopped sending. Send again on the PC; it continues where it stopped.');
            _afterTransfer();
          }
        });
        _progress(d, t, what, 'Receiving');
      },
      onImported: (res) {
        _stall?.cancel();
        busy = null;
        progress = null;
        unawaited(_installed(res));
        _afterTransfer();
      },
      onError: (e) {
        busy = null;
        say('Receiving failed: $e');
        _afterTransfer();
      },
    );
    try {
      await r.start();
    } catch (e) {
      say('Can’t start receiving: $e');
      return;
    }
    receiver = r;
    final responder = DiscoveryResponder(name: deviceName, id: deviceId, port: () => r.port ?? pushPort);
    try {
      await SystemChannel.multicastLock(true);
      await responder.start();
      _responder = responder;
    } catch (e) {
      say('This phone can’t be found automatically ($e). Use the address below on the PC.');
    }
    addresses = await lanAddresses();
    notifyListeners();
  }

  Future<void> stopReceiving() async {
    final r = receiver, d = _responder;
    if (r == null && d == null) return;
    receiver = null;
    _responder = null;
    d?.stop();
    await SystemChannel.multicastLock(false);
    await r?.stop();
    notifyListeners();
  }

  Future<String?> _onPair(PairRequest req) async {
    // New PCs are only allowed from the Import screen, never by auto-receive.
    if (!_held) {
      final msg = '${req.name} wants to send you mixes. To allow it, open Get mixes from PC, '
          'then send again from the PC.';
      say(msg);
      notify?.call(msg);
      return null;
    }
    showImportScreen?.call();
    final ok = await (confirmPair?.call(req) ?? Future.value(false));
    if (!ok) {
      say('Declined ${req.name}.');
      return null;
    }
    final token = newToken();
    trusted.removeWhere((t) => t.id == req.id && req.id.isNotEmpty);
    trusted.add(TrustedPc(req.id, req.name, token));
    await _saveTrusted();
    say('${req.name} can now send mixtapes to this phone.');
    return token;
  }

  // ------------------------------------------------------------ QR (pull)

  Future<void> connectPull(PullLink link) async {
    final got = await _run('Connecting to ${link.name ?? 'the PC'}…', () async {
      final c = await PullClient.reach(link);
      final list = await c.list();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return (c, list);
    });
    if (got == null) return;
    pullClient = got.$1;
    pullFrom = link.name ?? got.$1.base.host;
    remote = got.$2;
    notifyListeners();
    if (remote.isEmpty) {
      say('Connected, but the PC isn’t sharing a mix right now.');
    } else if (remote.length == 1) {
      await pullImport(remote.single);
    }
  }

  /// Manual fallback: "ip:port" and code typed from the PC screen.
  Future<void> connectPullManual(String address, String code) async {
    final a = address.trim().replaceFirst(RegExp(r'^https?://'), '');
    final parts = a.split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) : pullPort;
    if (parts.first.isEmpty || port == null) {
      say('Enter the PC address like 192.168.1.10:$pullPort');
      return;
    }
    await connectPull(PullLink(hosts: [parts.first], port: port, token: code.trim()));
  }

  Future<void> pullImport(RemoteMixtape m) async {
    final c = pullClient;
    if (c == null) return;
    await _run('Downloading ${m.name}', () async {
      final imp = await _importer();
      final staging = await _staging(Transport.pull);
      final dir = await c.download(m.id, staging,
          haveSong: imp.hasTrack,
          onProgress: (d, t, w) => _progress(d, t, w, 'Downloading'),
          cancelled: () => _cancel);
      try {
        final r = await imp.importPackage(dir, move: true, onProgress: _progress);
        await _installed(r);
        await c.reportDone(m.id, {'copied': r.copied, 'reused': r.reused, 'errors': r.errors});
        await _sendJournal(c);
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  }

  /// Hands the play/rating journal to the PC we just pulled from and trims
  /// what it acknowledged. Failures are only logged; the PC keeps a cursor,
  /// so a later sync resends safely.
  Future<void> _sendJournal(PullClient c) async {
    try {
      final j = await AppJournal.journal;
      final entries = await j.since(0);
      if (entries.isEmpty) return;
      final ack = await c.sendJournal(entries);
      if (ack == null || ack <= 0) return;
      await j.trimTo(ack < entries.last.seq ? ack : entries.last.seq);
    } catch (e) {
      debugPrint('Journal sync to PC failed: $e');
    }
  }

  // ------------------------------------------------------------- files

  Future<void> importFile(File f) => importFiles([f]);

  /// Imports several .beatsmix files one after another; the last one becomes
  /// the current mix.
  Future<void> importFiles(List<File> files) async {
    if (files.isEmpty) return;
    await _run('Opening ${p.basename(files.first.path)}', () async {
      final imp = await _importer();
      final staging = Directory(p.join((await _staging(Transport.zip)).path, 'x'));
      var ok = 0;
      ImportResult? last;
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        if (_cancel) break;
        final of = files.length > 1 ? ' (${i + 1} of ${files.length})' : '';
        busy = 'Opening ${p.basename(f.path)}$of';
        progress = null;
        notifyListeners();
        try {
          final r = await ZipTransport.import(f, staging, imp, onProgress: (d, t, w) {
            _progress(d, t, w);
            if (w != 'done') busy = 'Installing $w$of';
          });
          await _installed(r, apply: false);
          ok++;
          last = r;
        } on ImportException catch (e) {
          say('${p.basename(f.path)}: ${e.message}');
        } catch (e) {
          say('${p.basename(f.path)}: $e');
        } finally {
          if (f.path.contains('${Platform.pathSeparator}incoming${Platform.pathSeparator}')) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
      if (last != null) await app.applyImported(last);
      if (files.length > 1) {
        final msg = 'Imported $ok of ${files.length} mixtapes.';
        say(msg);
        notify?.call(msg);
      }
    });
  }

  Future<List<FoundPackage>> findPackages(Directory dir) async {
    await app.ensureStoragePermission();
    return discoverPackages(dir);
  }

  Future<void> importFolderPackage(FoundPackage f) async {
    await _run('Importing ${f.manifest.name}', () async {
      final imp = await _importer();
      await _installed(await imp.importPackage(f.dir, onProgress: _progress));
    });
  }

  // ---------------------------------------------------------- USB inbox

  /// Imports packages analyze-this copied over USB into [phoneInbox], and
  /// applies its journal ack (also on [onResume], which calls this).
  Future<void> scanInbox({bool quiet = false}) async {
    await applyUsbJournalAck();
    await _run('Checking USB inbox', () async {
      await app.ensureStoragePermission();
      final catalogFile = File(p.join(phoneInbox, albumCatalogName));
      var catalogFound = false;
      if (await albumCatalog.hasInbox(catalogFile)) {
        catalogFound = true;
        try {
          await albumCatalog.importInbox(catalogFile);
          final msg = 'Synced desktop catalogue from USB: ${albumCatalog.snapshot!.albums.length} albums (metadata only).';
          say(msg);
          notify?.call(msg);
        } catch (e) {
          final msg = 'USB catalogue sync failed; inbox retained for retry: $e';
          say(msg);
          notify?.call(msg);
        }
      }
      final imp = await _importer();
      final w = SyncdirWatcher(Directory(phoneInbox), imp, label: null, consume: true,
          onError: (e) => say('USB inbox: $e'));
      final done = await w.scanOnce(force: true);
      for (final r in done) {
        await _installed(r);
      }
      if (done.isEmpty && !catalogFound && !quiet) say('Nothing new from USB.');
      await writeInventory();
    });
  }

  // ------------------------------------------------------- sync folder

  Future<void> startWatcher(String root) async {
    watcher?.stop();
    final imp = await _importer();
    syncRoot = root;
    watcher = SyncdirWatcher(Directory(root), imp,
        label: null,
        onImported: (r) => unawaited(_installed(r)),
        onError: (e) => say('Sync folder: $e'))
      ..start();
    say('Watching $root');
    notifyListeners();
  }

  void stopWatcher() {
    watcher?.stop();
    watcher = null;
    notifyListeners();
  }

  Future<void> scanWatcherNow() async {
    final r = await watcher?.scanOnce(force: true) ?? const [];
    if (r.isEmpty) say('Nothing new in the sync folder');
  }

  @override
  void dispose() {
    albumCatalog.dispose();
    _stall?.cancel();
    _idleStop?.cancel();
    _responder?.stop();
    receiver?.stop();
    watcher?.stop();
    unawaited(SystemChannel.stopTransferService());
    super.dispose();
  }
}
