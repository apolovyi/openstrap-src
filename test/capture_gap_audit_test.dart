import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Sample _sample(int ts) => Sample(
      tsEpoch: ts,
      counter: ts,
      hr: 70,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 1,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

RawRecord _raw(int ts) => RawRecord(
      counter: ts,
      packetType: 47,
      hex: 'feed$ts',
      capturedAt: ts * 1000,
      recTs: ts,
    );

Future<void> _insert(Iterable<int> timestamps) async {
  for (final ts in timestamps) {
    await LocalDb.insertRecord(_raw(ts), _sample(ts));
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_capture_gap_audit_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('completed offload range with every second is continuous', () async {
    await _insert([1000, 1001, 1002, 1003, 1004, 1005]);

    final audit = await LocalDb.auditDecodedOneHzContinuity(
      frontierBefore: 1000,
      frontierAfter: 1005,
    );

    expect(audit['status'], 'continuous');
    expect(audit['gap_count'], 0);
    expect(audit['missing_seconds'], 0);
  });

  test('missing seconds inside the newly advanced frontier are identified', () async {
    await _insert([1006, 1009, 1010]);

    final audit = await LocalDb.auditDecodedOneHzContinuity(
      frontierBefore: 1005,
      frontierAfter: 1010,
    );

    expect(audit['status'], 'gaps_detected');
    expect(audit['gap_count'], 1);
    expect(audit['missing_seconds'], 2);
    expect(audit['largest_gap_missing_seconds'], 2);
    expect(audit['largest_gap_before_ts'], 1006);
    expect(audit['largest_gap_after_ts'], 1009);
  });

  test('persisted audit is available to diagnostics', () async {
    final audit = await LocalDb.auditAndPersistDecodedOneHzContinuity(
      frontierBefore: 1005,
      frontierAfter: 1010,
    );
    final row = await LocalDb.computeFreshness('capture_gap_audit');
    final stored = jsonDecode(row!['payload_json'] as String) as Map;

    expect(stored, audit);
    expect(stored['status'], 'gaps_detected');
  });

  test('a completed offload without frontier movement reports no new data', () async {
    final audit = await LocalDb.auditDecodedOneHzContinuity(
      frontierBefore: 1010,
      frontierAfter: 1010,
    );

    expect(audit['status'], 'no_new_data');
    expect(audit['gap_count'], 0);
  });
}
