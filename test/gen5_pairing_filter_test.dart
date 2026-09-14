// Pairing filter for WHOOP 5.0 / MG — the leftover from #238 after the
// transport landed in protocol#27 + edge#97.
//
// The 128-bit vendor service `fd4b0001-cce1-…` is already on main. What was
// never settled is whether a real band puts that UUID in the *primary*
// advertisement or only the scan response. A 128-bit UUID often does not fit
// the 31-byte AD; iOS then hashes it in the overflow area and AccessorySetupKit
// never sees it. The SIG member UUID `0xFD4B` (2 bytes) and the advertised
// local name (`WHOOP MGB…` / `WHOOP 5A…`) are what still fit.
//
// This is not a second codec. Edge still holds no wire-format. These tests pin
// the discovery surface: Dart scan filter, Info.plist, and ASK descriptors.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

String _readRepoFile(String posixPath) {
  final file = File(posixPath.split('/').join(Platform.pathSeparator));
  expect(file.existsSync(), isTrue,
      reason: 'run from the package root; missing $posixPath');
  return file.readAsStringSync();
}

void main() {
  group('16-bit member UUID is not the Bluetooth-base expansion', () {
    test('kWhoopMemberUuid16 is the short SIG assignment', () {
      expect(kWhoopMemberUuid16, 'fd4b');
      expect(kWhoopMemberUuid16, isNot('0000fd4b-0000-1000-8000-00805f9b34fb'));
      expect(GattProfile.gen5.service, isNot(startsWith('0000fd4b')));
      expect(GattProfile.gen5.service,
          'fd4b0001-cce1-4033-93ce-002d5875f58a');
    });
  });

  group('advertisementLooksLikeWhoop', () {
    test('matches gen4 and gen5 128-bit vendor prefixes', () {
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: [GattProfile.gen4.service],
        ),
        isTrue,
      );
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: [GattProfile.gen5.service],
        ),
        isTrue,
      );
    });

    test('matches the 16-bit member UUID in both platform spellings', () {
      // iOS reports 16-bit UUIDs short; Android expands them against the base.
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: const ['fd4b'],
        ),
        isTrue,
      );
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: const ['0000fd4b-0000-1000-8000-00805f9b34fb'],
        ),
        isTrue,
      );
    });

    test('matches a WHOOP MG advertised name with no service UUID yet', () {
      // Issue #237: the band shows up as WHOOP MGB… in system Bluetooth.
      expect(
        advertisementLooksLikeWhoop(
          platformName: 'WHOOP MGB1234',
          serviceUuids: const [],
        ),
        isTrue,
      );
    });

    test('rejects a Polar H10 advertising the standard HR service', () {
      expect(
        advertisementLooksLikeWhoop(
          platformName: 'Polar H10',
          serviceUuids: const ['0000180d-0000-1000-8000-00805f9b34fb'],
        ),
        isFalse,
      );
    });
  });

  group('whoopScanServiceUuids', () {
    test('filters on both 128-bit vendors and the 16-bit member UUID', () {
      final uuids = whoopScanServiceUuids().map((g) => g.str.toLowerCase());
      expect(uuids, contains(GattProfile.gen4.service));
      expect(uuids, contains(GattProfile.gen5.service));
      expect(
        uuids.any((u) => u == 'fd4b' || u.startsWith('0000fd4b')),
        isTrue,
        reason: '16-bit 0xFD4B must be its own scan filter — the 128-bit '
            'vendor UUID is a different value and will not match a band that '
            'only advertised the 2-byte form',
      );
    });
  });

  group('iOS ASK / Info.plist stay in lockstep with the Dart filter', () {
    late String plist;
    late String swift;
    late String engine;

    setUpAll(() {
      plist = _readRepoFile('ios/Runner/Info.plist');
      swift = _readRepoFile('ios/Runner/AccessorySetup.swift');
      // M2 §15: scan() moved from ble_engine.dart to transport.dart (a `part
      // of` extension, same library) — the literals this test pins moved
      // with it.
      engine = _readRepoFile('lib/ble/transport.dart');
    });

    test('Info.plist declares the 128-bit vendor service and 16-bit FD4B', () {
      expect(plist, contains('FD4B0001-CCE1-4033-93CE-002D5875F58A'));
      expect(plist, contains('<string>FD4B</string>'));
      // The Bluetooth-base expansion may be named in a comment as the thing
      // we must NOT declare. It must never be an actual ASK service string.
      expect(
        plist,
        isNot(contains('<string>0000FD4B-0000-1000-8000-00805F9B34FB</string>')),
      );
    });

    test('Info.plist declares the WHOOP name net for ASK', () {
      expect(plist, contains('<key>NSAccessorySetupBluetoothNames</key>'));
      expect(plist, contains('<string>WHOOP</string>'));
    });

    test('ASK has a separate 16-bit FD4B descriptor, not AND-combined', () {
      // The 128-bit gen5 vendor UUID is now sourced from Info.plist (generated
      // from kBandRegistry), checked above; this test pins the EXTRA 16-bit
      // fallback item that is layered on top in Swift.
      // A 16-bit CBUUID("FD4B") is its own picker item. Criteria inside one
      // ASDiscoveryDescriptor AND-combine, so folding this onto the 128-bit
      // item would match nothing if the band advertised only one form.
      expect(swift, contains('whoopMemberUUID16'));
      expect(
        swift,
        contains('CBUUID(string: AccessorySetup.whoopMemberUUID16)'),
      );
    });

    test(
        'no bare name-substring descriptor exists — it crashed every '
        '"search for devices" tap once (TestFlight v0.9.29, '
        'A3457926-FD0D-48A7-9C6B-DCC6958276BF)', () {
      expect(swift, isNot(contains('bluetoothNameSubstring')),
          reason: 'a live bluetoothNameSubstring assignment is the exact '
              'crash this test exists to catch');
    });

    test(
        'engine scan filters on the registry service list plus the '
        '16-bit member UUID fallback, not a second hand-written UUID list',
        () {
      expect(engine, contains('for (final e in kFramedBands) Guid(e.service)'));
      expect(engine, contains('Guid(kWhoopMemberUuid16)'));
      expect(engine, contains("s == kWhoopMemberUuid16"));
    });

    test('one picker offers every declared service and the member UUID', () {
      expect(swift, contains('var items = services.map'));
      expect(swift, contains('items.append(makeItem("WHOOP 5.0 / MG")'));
      expect('session.showPicker(for: items)'.allMatches(swift), hasLength(1));
    });

    test('the native bridge delegates presentation and dismissal separately', () {
      expect(swift, contains('private let picker = AccessoryPickerLifecycle()'));
      expect(swift, contains('self.picker.presentationCompleted(token: token, error: failure)'));
      expect(swift, contains('case .pickerDidDismiss:'));
      expect(swift, contains('picker.dismissed(authorizedIds: authorizedIds)'));
      expect(swift, contains('case .accessoryAdded, .accessoryChanged:'));
      expect(swift, contains('guard accessory.state == .authorized'));
    });
  });
}
