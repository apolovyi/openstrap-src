// whoop_import.dart — import WHOOP derived CSV snapshots.

import 'dart:convert';
import 'dart:io';

import '../compute/derivation_engine.dart' show kAlgoVersion, DerivationEngine;
import '../compute/profile.dart';
import '../compute/substrate.dart' show localDateLabel;
import '../data/db.dart';

class WhoopImportResult {
  final int days;
  final int workouts;
  final int skippedExistingDays;
  final bool finalizationDeferred;

  const WhoopImportResult({
    required this.days,
    required this.workouts,
    required this.skippedExistingDays,
    required this.finalizationDeferred,
  });
}

class _Row {
  final Map<String, int> col;
  final List<String> f;
  const _Row(this.col, this.f);

  String get(List<String> names) => _pick(names).$2;
  String header(List<String> names) => _pick(names).$1;

  (String, String) _pick(List<String> names) {
    for (final name in names) {
      final index = col[name];
      if (index != null && index < f.length) return (name, f[index].trim());
    }
    return ('', '');
  }
}

class WhoopImporter {
  static const List<String> _energyCols = [
    'energy burned (cal)',
    'energy burned (kcal)',
    'energy burned (kilocalories)',
    'energy burned (kj)',
    'energy burned (kilojoules)',
    'energy burned (kilojoule)',
    'energy burned',
  ];

  static Future<WhoopImportResult> importFiles(
    List<String> paths, {
    DerivationEngine? engine,
    Profile? profile,
    void Function(int done)? onProgress,
  }) async {
    if ((engine == null) != (profile == null)) {
      throw ArgumentError('engine and profile must be supplied together');
    }

    final days = <WhoopDayWrite>[];
    final workouts = <Map<String, Object?>>[];
    final seenDays = <String>{};
    final seenWorkouts = <String>{};

    for (final path in paths) {
      final rows = await _readCsv(path);
      if (rows.length < 2) {
        throw FormatException('WHOOP CSV has no data rows: $path');
      }
      final header = rows.first;
      final col = <String, int>{};
      for (var index = 0; index < header.length; index++) {
        final name = header[index].trim().toLowerCase();
        if (name.isEmpty) continue;
        if (col.containsKey(name)) {
          throw FormatException('duplicate WHOOP CSV header "$name": $path');
        }
        col[name] = index;
      }
      final kind = _classify(col);
      if (kind == _Kind.unknown) {
        throw FormatException('unrecognized WHOOP CSV headers: $path');
      }

      for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
        final fields = rows[rowIndex];
        if (fields.every((field) => field.trim().isEmpty)) continue;
        final row = _Row(col, fields);
        if (kind == _Kind.day) {
          final prepared = _prepareDay(row, path, rowIndex + 1);
          if (!seenDays.add(prepared.dayId)) {
            throw FormatException(
              'duplicate WHOOP local day ${prepared.dayId}: $path:${rowIndex + 1}',
            );
          }
          days.add(prepared);
          onProgress?.call(days.length);
        } else {
          final prepared = _prepareWorkout(row, path, rowIndex + 1);
          final id = prepared['id'] as String;
          if (!seenWorkouts.add(id)) {
            throw FormatException(
              'duplicate WHOOP workout $id: $path:${rowIndex + 1}',
            );
          }
          workouts.add(prepared);
        }
      }
    }

    final committed = await LocalDb.putWhoopImport(
      days: days,
      workouts: workouts,
      algoVersion: kAlgoVersion,
    );
    final deferred = engine != null && !profile!.isComplete;
    if (engine != null && !deferred) await engine.finalizeImport(profile!);
    return WhoopImportResult(
      days: committed.days,
      workouts: committed.workouts,
      skippedExistingDays: committed.skippedExistingDays,
      finalizationDeferred: deferred,
    );
  }

  static WhoopDayWrite _prepareDay(_Row row, String path, int rowNumber) {
    String get(List<String> names) => row.get(names);
    final wakeTs = _parseTs(
      get(['wake onset', 'sleep onset', 'cycle start time']),
    );
    final cycleStart = _parseTs(get(['cycle start time', 'sleep onset']));
    final anchor = wakeTs ?? cycleStart;
    if (anchor == null) {
      throw FormatException('missing WHOOP day timestamp: $path:$rowNumber');
    }
    final explicitDay = get(['local day']);
    final date = explicitDay.isEmpty
        ? localDateLabel(anchor)
        : _strictDay(explicitDay, path, rowNumber);

    double? number(List<String> names, {double? minimum, double? maximum}) {
      final raw = get(names);
      if (raw.isEmpty) return null;
      final value = double.tryParse(raw);
      if (value == null || !value.isFinite) {
        throw FormatException(
          'invalid numeric WHOOP value "$raw": $path:$rowNumber',
        );
      }
      if (minimum != null && value < minimum ||
          maximum != null && value > maximum) {
        throw FormatException(
          'out-of-range WHOOP value "$raw": $path:$rowNumber',
        );
      }
      return value;
    }

    final recovery = number(
      ['recovery score %', 'recovery score'],
      minimum: 0,
      maximum: 100,
    );
    final rhr = number([
      'resting heart rate (bpm)',
      'resting heart rate',
    ], minimum: 0);
    final rmssd = number([
      'heart rate variability (ms)',
      'heart rate variability (rmssd) (ms)',
    ], minimum: 0);
    final strain = number(['day strain', 'strain'], minimum: 0);
    final totalCalories = _kcal(
      get(_energyCols),
      row.header(_energyCols),
      path,
      rowNumber,
    );
    final resp = number([
      'respiratory rate (rpm)',
      'respiratory rate',
    ], minimum: 0);
    final spo2Pct = number(
      ['blood oxygen %', 'blood oxygen'],
      minimum: 0,
      maximum: 100,
    );
    final skinTempC = number([
      'skin temp (celsius)',
      'skin temperature (celsius)',
    ]);
    final asleepMin = number([
      'asleep duration (min)',
      'asleep duration (minutes)',
    ], minimum: 0);
    final inBedMin = number([
      'in bed duration (min)',
      'in bed duration (minutes)',
    ], minimum: 0);
    final lightMin = number([
      'light sleep duration (min)',
      'light sleep duration (minutes)',
    ], minimum: 0);
    final deepMin = number([
      'deep (sws) duration (min)',
      'deep sleep duration (min)',
      'deep (sws) duration (minutes)',
    ], minimum: 0);
    final remMin = number([
      'rem duration (min)',
      'rem duration (minutes)',
    ], minimum: 0);
    final awakeMin = number([
      'awake duration (min)',
      'awake duration (minutes)',
    ], minimum: 0);
    final efficiencyPct = number(
      ['sleep efficiency %', 'sleep efficiency'],
      minimum: 0,
      maximum: 100,
    );
    final performancePct = number(
      ['sleep performance %', 'sleep performance'],
      minimum: 0,
      maximum: 100,
    );
    final sleepOnset = _parseTs(get(['sleep onset']));
    final sleepWake = _parseTs(get(['wake onset']));

    final hasSleep = asleepMin != null && asleepMin > 0;
    Map<String, dynamic>? accounting;
    Map<String, dynamic>? window;
    if (hasSleep) {
      final sleepPeriodSec = (inBedMin ?? asleepMin) * 60;
      accounting = {
        'tst_sec': (asleepMin * 60).round(),
        'in_bed_sec': sleepPeriodSec.round(),
        'efficiency_pct': efficiencyPct,
        'light_sec': lightMin == null ? null : (lightMin * 60).round(),
        'deep_sec': deepMin == null ? null : (deepMin * 60).round(),
        'rem_sec': remMin == null ? null : (remMin * 60).round(),
        'nrem_sec': lightMin != null && deepMin != null
            ? ((lightMin + deepMin) * 60).round()
            : null,
        'wake_sec': awakeMin == null ? null : (awakeMin * 60).round(),
        'deep_low_confidence': true,
        'imported': true,
      };
      window = {
        'onset_ms': sleepOnset == null ? null : sleepOnset * 1000,
        'offset_ms': sleepWake == null ? null : sleepWake * 1000,
        'spt_sec': sleepPeriodSec.round(),
      };
    }

    Map<String, dynamic> envelope(Object? value, {String tier = 'HIGH'}) => {
      'value': value ?? '—',
      'confidence': value == null ? 0 : 0.7,
      'tier': tier,
      'inputs_used': const ['whoop_export'],
    };

    final bundle = <String, dynamic>{
      'date': date,
      'imported': true,
      'source': 'whoop_export',
      'day_confidence': 0.7,
      'flags': const ['IMPORTED_WHOOP_BETA'],
      'clinical': {
        if (rmssd != null) 'hrv_time': envelope({'rmssd': rmssd}),
        if (rhr != null) 'resting_hr': envelope({'low30Mean': rhr}),
        if (strain != null) 'strain': envelope(strain, tier: 'ESTIMATE'),
      },
      if (accounting != null)
        'sleep': {
          'window': envelope(window),
          'accounting': envelope(accounting, tier: 'ESTIMATE'),
        },
      'vendor': {
        'whoop': {
          'blood_oxygen_pct': spo2Pct,
          'skin_temp_c': skinTempC,
          'sleep_performance_pct': performancePct,
          'total_energy_kcal': totalCalories,
        },
      },
      'scalars': {
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': recovery,
        'strain': strain,
        'resp_rate': resp,
        'calories_total': totalCalories,
        'spo2_pct': spo2Pct,
        'skin_temp_c': skinTempC,
        'tst_min': asleepMin,
        'rem_min': remMin,
        'deep_min': deepMin,
        'light_min': lightMin,
        'efficiency': efficiencyPct,
        'sleep_performance': performancePct,
      },
    };

    return WhoopDayWrite(
      dayId: date,
      payloadJson: jsonEncode(bundle),
      windowJson: jsonEncode(window ?? const {}),
      rhr: rhr,
      rmssd: rmssd,
      readiness: recovery,
      series: {
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': recovery,
        'strain': strain,
        'resp_rate': resp,
        'calories_total': totalCalories,
        'spo2_pct': spo2Pct,
        'skin_temp_c': skinTempC,
        'tst_min': asleepMin,
        'rem_min': remMin,
        'deep_min': deepMin,
        'light_min': lightMin,
        'efficiency': efficiencyPct,
        'sleep_performance': performancePct,
      },
    );
  }

  static Map<String, Object?> _prepareWorkout(
    _Row row,
    String path,
    int rowNumber,
  ) {
    String get(List<String> names) => row.get(names);
    final start = _parseTs(get(['workout start time', 'start time']));
    final end = _parseTs(get(['workout end time', 'end time']));
    if (start == null || end == null || end < start) {
      throw FormatException('invalid WHOOP workout bounds: $path:$rowNumber');
    }
    double? number(List<String> names, {double? minimum}) {
      final raw = get(names);
      if (raw.isEmpty) return null;
      final value = double.tryParse(raw);
      if (value == null ||
          !value.isFinite ||
          minimum != null && value < minimum) {
        throw FormatException(
          'invalid numeric WHOOP value "$raw": $path:$rowNumber',
        );
      }
      return value;
    }

    return {
      'id': 'whoop_$start',
      'start_ts': start,
      'end_ts': end,
      'type': _slug(get(['activity name', 'activity'])),
      'status': 'done',
      'source': 'whoop',
      'calories': _kcal(
        get(_energyCols),
        row.header(_energyCols),
        path,
        rowNumber,
      ),
      'strain': number(['activity strain', 'strain'], minimum: 0),
      'max_hr': number([
        'max hr (bpm)',
        'max heart rate (bpm)',
      ], minimum: 0)?.toInt(),
      'duration_min': ((end - start) / 60).round(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static _Kind _classify(Map<String, int> columns) {
    bool has(String key) => columns.containsKey(key);
    if (has('activity name') || has('workout start time')) return _Kind.workout;
    if (has('local day') ||
        has('recovery score %') ||
        has('asleep duration (min)') ||
        has('day strain') ||
        has('sleep onset')) {
      return _Kind.day;
    }
    return _Kind.unknown;
  }

  static String _strictDay(String value, String path, int rowNumber) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) {
      throw FormatException(
        'invalid WHOOP local day "$value": $path:$rowNumber',
      );
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      throw FormatException(
        'invalid WHOOP local day "$value": $path:$rowNumber',
      );
    }
    return value;
  }

  static int? _parseTs(String value) {
    if (value.isEmpty) return null;
    var text = value.trim();
    final compactOffset = RegExp(r'([+-]\d{2})(\d{2})$').firstMatch(text);
    if (compactOffset != null) {
      text =
          '${text.substring(0, compactOffset.start)}'
          '${compactOffset.group(1)}:${compactOffset.group(2)}';
    }
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
    final date = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
    if (date == null) return null;
    return DateTime(
          int.parse(date.group(1)!),
          int.parse(date.group(2)!),
          int.parse(date.group(3)!),
        ).millisecondsSinceEpoch ~/
        1000;
  }

  static double? _kcal(
    String value,
    String header,
    String path,
    int rowNumber,
  ) {
    if (value.isEmpty) return null;
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      throw FormatException('invalid WHOOP energy "$value": $path:$rowNumber');
    }
    final normalizedHeader = header.toLowerCase();
    if (normalizedHeader.contains('kj') ||
        normalizedHeader.contains('kilojoule')) {
      return parsed / 4.184;
    }
    if (normalizedHeader.contains('cal')) return parsed;
    return null;
  }

  static String _slug(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isEmpty ? 'other' : normalized;
  }

  static Future<List<List<String>>> _readCsv(String path) async {
    final lines = File(
      path,
    ).openRead().transform(utf8.decoder).transform(const LineSplitter());
    final output = <List<String>>[];
    await for (final line in lines) {
      if (line.isEmpty) continue;
      output.add(_splitCsvLine(line));
    }
    return output;
  }

  static List<String> _splitCsvLine(String line) {
    final output = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var index = 0; index < line.length; index++) {
      final char = line[index];
      if (quoted) {
        if (char == '"') {
          if (index + 1 < line.length && line[index + 1] == '"') {
            field.write('"');
            index++;
          } else {
            quoted = false;
          }
        } else {
          field.write(char);
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == ',') {
        output.add(field.toString());
        field.clear();
      } else {
        field.write(char);
      }
    }
    output.add(field.toString());
    return output;
  }
}

enum _Kind { day, workout, unknown }
