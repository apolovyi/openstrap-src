// Simple append-only file logger for field debugging.
//
// Writes to the app's external files dir on Android so it can be pulled with a
// plain `adb pull` (no run-as needed):
//   /storage/emulated/0/Android/data/wtf.openstrap.openstrap_edge/files/openstrap_sync.log

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

@visibleForTesting
Future<Directory> resolveFileLogDirectory({
  required bool isAndroid,
  required Future<Directory?> Function() externalDirectory,
  required Future<Directory> Function() documentsDirectory,
}) async {
  if (!isAndroid) return documentsDirectory();
  try {
    return await externalDirectory() ?? await documentsDirectory();
  } catch (_) {
    return documentsDirectory();
  }
}

class FileLog {
  static File? _file;
  static Future<void>? _initializing;
  static Future<void> _writeTail = Future<void>.value();

  static Future<void> _ensure() => _initializing ??= _initialize();

  static Future<void> _initialize() async {
    try {
      final dir = await resolveFileLogDirectory(
        isAndroid: Platform.isAndroid,
        externalDirectory: getExternalStorageDirectory,
        documentsDirectory: getApplicationDocumentsDirectory,
      );
      _file = File('${dir.path}/openstrap_sync.log');
    } catch (_) {
      _file = null;
      _initializing = null;
    }
  }

  static Future<void> write(String line) {
    final timestamp = DateTime.now().toIso8601String();
    _writeTail = _writeTail.then((_) async {
      await _ensure();
      try {
        await _file?.writeAsString(
          '$timestamp $line\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {}
    });
    return _writeTail;
  }

  static Future<String?> path() async {
    await _ensure();
    return _file?.path;
  }

  static Future<void> clear() {
    _writeTail = _writeTail.then((_) async {
      await _ensure();
      try {
        await _file?.writeAsString('');
      } catch (_) {}
    });
    return _writeTail;
  }
}
