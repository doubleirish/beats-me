import 'app_state.dart';

/// How the Mixes list is ordered.
enum MixSort {
  imported('Recently imported'),
  name('Name'),
  lastPlayed('Last played'),
  size('Size');

  const MixSort(this.label);
  final String label;

  static MixSort parse(String? name) =>
      MixSort.values.firstWhere((s) => s.name == name, orElse: () => MixSort.imported);
}

/// Mixes whose name or program contains every word of [query] (any case).
List<MixSummary> filterMixes(List<MixSummary> mixes, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return List.of(mixes);
  return [
    for (final m in mixes)
      if (words.every((w) => '${m.name} ${m.programName ?? ''}'.toLowerCase().contains(w))) m,
  ];
}

/// A sorted copy of [mixes]. Name is A–Z; the others put the newest/largest
/// first, with never-played/unknown-size mixes last.
List<MixSummary> sortMixes(List<MixSummary> mixes, MixSort sort) {
  int byName(MixSummary a, MixSummary b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  int byImported(MixSummary a, MixSummary b) => b.modified.compareTo(a.modified);
  final out = List.of(mixes);
  switch (sort) {
    case MixSort.imported:
      out.sort(byImported);
    case MixSort.name:
      out.sort(byName);
    case MixSort.lastPlayed:
      out.sort((a, b) {
        final x = a.lastPlayed, y = b.lastPlayed;
        if (x == null || y == null) return x == y ? byImported(a, b) : (x == null ? 1 : -1);
        final c = y.compareTo(x);
        return c != 0 ? c : byImported(a, b);
      });
    case MixSort.size:
      out.sort((a, b) {
        final c = (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1);
        return c != 0 ? c : byName(a, b);
      });
  }
  return out;
}

/// "820 KB", "1.4 GB".
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(v >= 100 || i < 2 ? 0 : 1)} ${units[i]}';
}

/// "today", "yesterday", "3 days ago", "12 Mar 2026".
String playedLabel(DateTime when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = DateTime(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime(when.year, when.month, when.day)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${when.day} ${months[when.month - 1]} ${when.year}';
}
