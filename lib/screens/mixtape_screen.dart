import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import '../services/app_state.dart';
import '../services/mixtape_controller.dart';

/// Import mixtapes (songs + metadata) from analyze-this. Wi-Fi receiving
/// starts by itself; the other ways are one tap each.
class MixtapeScreen extends StatefulWidget {
  const MixtapeScreen({super.key});

  static bool isOpen = false;

  @override
  State<MixtapeScreen> createState() => _MixtapeScreenState();
}

class _MixtapeScreenState extends State<MixtapeScreen> {
  late final MixtapeController c = context.read<AppState>().mixtapes;
  final _address = TextEditingController();
  final _code = TextEditingController();
  List<FoundPackage> _found = [];
  String? _folderNote;

  @override
  void initState() {
    super.initState();
    MixtapeScreen.isOpen = true;
    c.startReceiving();
  }

  @override
  void dispose() {
    MixtapeScreen.isOpen = false;
    c.releaseReceiving();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final link = await Navigator.push<PullLink>(
        context, MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (link != null) await c.connectPull(link);
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final files = [for (final f in picked) if (f.path != null) File(f.path!)];
    if (files.isNotEmpty) await c.importFiles(files);
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Folder with exported mixtapes');
    if (dir == null) return;
    final found = await c.findPackages(Directory(dir));
    setState(() {
      _found = found;
      _folderNote = found.isEmpty ? 'No mixtapes found in $dir' : null;
    });
  }

  Future<void> _pickSync() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Sync folder');
    if (dir != null) await c.startWatcher(dir);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Get mixes from PC')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final busy = c.busy != null;
          return ListView(padding: const EdgeInsets.all(12), children: [
            if (busy)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.busy!, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: c.progress),
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(onPressed: c.cancel, child: const Text('Cancel'))),
                  ]),
                ),
              ),
            _action(
              icon: Icons.wifi,
              title: 'Wi-Fi',
              body: c.receiving
                  ? 'Ready. On the PC press Send › Wi-Fi to phone › “${c.deviceName}”. Phone and PC '
                      'must be on the same Wi-Fi. '
                      '${c.autoReceive && c.trusted.isNotEmpty ? 'Allowed PCs can send whenever beats-me '
                          'is open; a new PC needs this screen open.' : 'Keep this screen open.'}'
                  : 'Not receiving.',
              children: [
                if (c.receiving)
                  Text(
                      'If the PC can’t find this phone, enter under Advanced on the PC: '
                      '${c.addresses.isEmpty ? '(no Wi-Fi)' : c.addresses.first}:${c.receiver!.port}  '
                      'code ${c.receiver!.token}',
                      style: t.bodySmall)
                else
                  FilledButton.tonal(onPressed: c.startReceiving, child: const Text('Start receiving')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Receive mixes from PC while beats-me is open'),
                  subtitle: Text(c.trusted.isEmpty
                      ? 'Starts once you’ve allowed a PC here.'
                      : 'Allowed PCs can send without opening this screen.'),
                  value: c.autoReceive,
                  onChanged: (v) => c.setAutoReceive(v),
                ),
              ],
            ),
            _action(
              icon: Icons.qr_code_scanner,
              title: 'Scan QR code',
              body: 'On the PC choose “Phone downloads (QR code)”, then scan the code it shows.',
              children: [
                FilledButton.tonal(onPressed: busy ? null : _scan, child: const Text('Scan QR code')),
                if (c.remote.length > 1) ...[
                  const SizedBox(height: 8),
                  Text('Mixes shared by ${c.pullFrom}:', style: t.bodySmall),
                  for (final m in c.remote)
                    ListTile(
                      dense: true,
                      title: Text(m.name),
                      subtitle: Text('${m.tracks} songs, ${formatBytes(m.bytes)}'),
                      trailing: const Icon(Icons.download),
                      onTap: busy ? null : () => c.pullImport(m),
                    ),
                ],
              ],
            ),
            _action(
              icon: Icons.file_open_outlined,
              title: 'Open a .beatsmix file',
              body: 'Got the file by Quick Share, email, Drive or cable? Tap it in Files, or pick it here.',
              children: [
                FilledButton.tonal(onPressed: busy ? null : _pickFile, child: const Text('Choose file…')),
              ],
            ),
            _action(
              icon: Icons.usb,
              title: 'USB cable',
              body: 'On the PC choose “USB cable”. It imports by itself; if not, tap below.',
              children: [
                FilledButton.tonal(
                    onPressed: busy ? null : () => c.scanInbox(), child: const Text('Check for USB mixes')),
              ],
            ),
            ExpansionTile(
              title: const Text('Advanced'),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _sub('Exported folder', 'Pick a folder analyze-this exported (copied to the phone).', [
                  OutlinedButton(onPressed: busy ? null : _pickFolder, child: const Text('Choose folder…')),
                  if (_folderNote != null) Text(_folderNote!),
                  for (final f in _found)
                    ListTile(
                      dense: true,
                      title: Text(f.manifest.name),
                      subtitle: Text('${f.manifest.tracks.length} songs · ${Transport.title(f.manifest.transport)}'),
                      trailing: const Icon(Icons.download),
                      onTap: busy ? null : () => c.importFolderPackage(f),
                    ),
                ]),
                _sub('Sync folder', 'Watch a folder a sync app (Syncthing, Drive…) fills from the PC.', [
                  if (c.watching) ...[
                    Text('Watching ${c.syncRoot}'),
                    Wrap(spacing: 8, children: [
                      OutlinedButton(onPressed: c.scanWatcherNow, child: const Text('Scan now')),
                      OutlinedButton(onPressed: c.stopWatcher, child: const Text('Stop')),
                    ]),
                  ] else
                    OutlinedButton(onPressed: _pickSync, child: const Text('Choose sync folder…')),
                ]),
                _sub('Download by address', 'If scanning isn’t possible: type what the PC shows under the QR code.', [
                  TextField(
                      controller: _address,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(labelText: 'PC address (e.g. 192.168.1.10:47822)', isDense: true)),
                  TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Code', isDense: true)),
                  const SizedBox(height: 6),
                  OutlinedButton(
                      onPressed: busy ? null : () => c.connectPullManual(_address.text, _code.text),
                      child: const Text('Connect')),
                ]),
                _sub('Trusted PCs', 'PCs allowed to send over Wi-Fi without asking.', [
                  if (c.trusted.isEmpty) const Text('None yet.'),
                  for (final pc in c.trusted)
                    ListTile(
                      dense: true,
                      title: Text(pc.name),
                      trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => c.forgetPc(pc.id)),
                    ),
                ]),
              ],
            ),
            const Divider(),
            Text('Activity', style: t.titleSmall),
            if (c.log.isEmpty) const Text('Nothing yet.'),
            for (final line in c.log)
              Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(line)),
          ]);
        },
      ),
    );
  }

  Widget _action(
          {required IconData icon,
          required String title,
          required String body,
          required List<Widget> children}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                Text(body),
                const SizedBox(height: 8),
                ...children,
              ]),
            ),
          ]),
        ),
      );

  Widget _sub(String title, String help, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          Text(help, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          ...children,
        ]),
      );
}

/// Full-screen camera that returns the first beats-me QR link it sees.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;
  String? _hint;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final link = PullLink.parse(b.rawValue ?? '');
      if (link != null) {
        _done = true;
        Navigator.pop(context, link);
        return;
      }
    }
    setState(() => _hint = 'That’s not a beats-me code. Scan the code in analyze-this’s Send window.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan the code on the PC')),
        body: Stack(children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    'The camera isn’t available (${error.errorCode.name}). Allow camera access in '
                    'Settings, or use Advanced › Download by address.',
                    textAlign: TextAlign.center),
              ),
            ),
          ),
          if (_hint != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                  color: Colors.black54, padding: const EdgeInsets.all(12), child: Text(_hint!)),
            ),
        ]),
      );
}
