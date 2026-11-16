import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/cast_controller.dart';

/// App-bar button that opens the "Play on…" sheet.
class CastButton extends StatelessWidget {
  const CastButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CastController>();
    return IconButton(
      tooltip: c.isCasting ? 'Playing on ${c.casting!.name}' : 'Play on…',
      icon: Icon(c.isCasting ? Icons.cast_connected : Icons.cast,
          color: c.isCasting ? Theme.of(context).colorScheme.primary : null),
      onPressed: () {
        final c = context.read<CastController>();
        if (c.devices.isEmpty) c.scan();
        showDialog<void>(
          context: context,
          builder: (_) => ChangeNotifierProvider.value(value: c, child: const _CastDialog()),
        );
      },
    );
  }
}

class _CastDialog extends StatelessWidget {
  const _CastDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CastController>();
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(children: [
        const Expanded(child: Text('Play on…')),
        if (c.scanning)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          IconButton(tooltip: 'Search again', icon: const Icon(Icons.refresh), onPressed: c.scan),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(c.error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.smartphone),
              title: const Text('This phone'),
              trailing: c.isCasting ? null : const Icon(Icons.check),
              onTap: c.isCasting ? c.stop : null,
            ),
            for (final d in c.devices)
              ListTile(
                dense: true,
                leading: const Icon(Icons.cast),
                title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: d.model == null ? null : Text(d.model!),
                trailing: c.connecting == d
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : c.casting == d
                        ? const Icon(Icons.check)
                        : null,
                onTap: c.casting == d ? null : () => c.cast(d),
              ),
            const SizedBox(height: 8),
            Text('Casting loses crossfade and loudness levelling.', style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
