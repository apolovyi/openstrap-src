import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completing onboarding profile finalizes deferred WHOOP rollups', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.dbName = 'whoop_profile_finalize_test.db';
    final dbPath = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(dbPath);
    final directory = Directory.systemTemp.createTempSync('whoop_profile_finalize');
    AppState? app;
    final csv = File(p.join(directory.path, 'days.csv'));
    csv.writeAsStringSync(
      'Local day,Cycle start time,Wake onset,Recovery score %,'
      'Resting heart rate (bpm),Heart rate variability (ms)\n'
      '2020-02-01,2020-02-01T00:00:00Z,2020-02-01T08:00:00Z,50,60,40\n'
      '2020-02-02,2020-02-02T00:00:00Z,2020-02-02T08:00:00Z,60,61,41\n'
      '2020-02-03,2020-02-03T00:00:00Z,2020-02-03T08:00:00Z,70,62,42\n',
    );
    try {
      final imported = await WhoopImporter.importFiles(
        [csv.path],
        engine: DerivationEngine(),
        profile: const Profile(),
      );
      expect(imported.finalizationDeferred, isTrue);
      expect(await LocalDb.baseline('crossday'), isNull);

      app = AppState();
      await app.updateProfile({
        'age': 40,
        'weight_kg': 75.0,
        'height_cm': 180.0,
        'sex': 'm',
      });
      expect(app.profileComplete, isTrue);
      expect(await LocalDb.baseline('crossday'), isNotNull);
    } finally {
      app?.dispose();
      await LocalDb.close();
      await databaseFactory.deleteDatabase(dbPath);
      directory.deleteSync(recursive: true);
    }
  });
}
