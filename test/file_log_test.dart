import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/file_log.dart';

void main() {
  test('iOS uses the application documents directory', () async {
    var externalCalled = false;
    final directory = await resolveFileLogDirectory(
      isAndroid: false,
      externalDirectory: () async {
        externalCalled = true;
        return Directory('/external');
      },
      documentsDirectory: () async => Directory('/documents'),
    );

    expect(directory.path, '/documents');
    expect(externalCalled, isFalse);
  });

  test('Android uses the external files directory when available', () async {
    final directory = await resolveFileLogDirectory(
      isAndroid: true,
      externalDirectory: () async => Directory('/external'),
      documentsDirectory: () async => Directory('/documents'),
    );

    expect(directory.path, '/external');
  });

  test(
    'Android falls back when the external-directory plugin throws',
    () async {
      final directory = await resolveFileLogDirectory(
        isAndroid: true,
        externalDirectory: () async => throw UnsupportedError('unavailable'),
        documentsDirectory: () async => Directory('/documents'),
      );

      expect(directory.path, '/documents');
    },
  );
}
