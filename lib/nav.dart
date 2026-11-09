import 'package:flutter/material.dart';

/// App-wide keys so services can show dialogs, pages and snackbars (e.g. a
/// pairing request or a file opened from another app).
final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void toast(String text) =>
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
