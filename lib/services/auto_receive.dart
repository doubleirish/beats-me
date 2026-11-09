/// What to do with the Wi-Fi receiver right now.
enum ReceiveAction { start, stop, keep }

/// Rules for "Receive mixes from PC while beats-me is open", kept free of
/// Flutter and I/O so they can be tested on their own.
class AutoReceive {
  static const prefKey = 'auto_receive';

  /// The setting as the user sees it: their choice, else on once a PC is
  /// trusted.
  static bool enabled({bool? setting, required int trustedCount}) => setting ?? trustedCount > 0;

  /// Whether the receiver should run without the Import screen open. Only
  /// trusted PCs can send then, so it's pointless before one is paired.
  static bool wanted({bool? setting, required int trustedCount, required bool foreground}) =>
      foreground && trustedCount > 0 && enabled(setting: setting, trustedCount: trustedCount);

  /// [held] is true while the Import screen keeps the receiver open; it is
  /// never stopped then. A running transfer is never cut off either. Starting
  /// only happens in the foreground (on launch or resume).
  static ReceiveAction decide({
    bool? setting,
    required int trustedCount,
    required bool foreground,
    required bool held,
    required bool receiving,
    required bool transferring,
  }) {
    final auto = wanted(setting: setting, trustedCount: trustedCount, foreground: foreground);
    if (!receiving) return auto ? ReceiveAction.start : ReceiveAction.keep;
    if (held || auto || transferring) return ReceiveAction.keep;
    return ReceiveAction.stop;
  }
}
