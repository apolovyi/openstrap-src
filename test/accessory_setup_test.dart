import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/accessory_setup.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('openstrap/accessory_setup');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('picker remains pending until native authorization completes', () async {
    final native = Completer<String>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return native.future;
    });
    var completed = false;
    final pending = AccessorySetup.showPicker().then((id) {
      completed = true;
      return id;
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'showPicker');
    expect(calls.single.arguments, {'addAnother': false});
    expect(completed, isFalse);
    native.complete('synthetic-selected-band');
    expect(await pending, 'synthetic-selected-band');
  });

  test(
    'only the explicitly saved identity can bypass the native picker',
    () async {
      late MethodCall received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return 'synthetic-saved-band';
      });
      await AccessorySetup.showPicker(existingRemoteId: 'synthetic-saved-band');
      expect(received.arguments, {
        'addAnother': false,
        'existingRemoteId': 'synthetic-saved-band',
      });
      await AccessorySetup.showPicker(addAnother: true);
      expect(received.arguments, {'addAnother': true});
    },
  );

  test(
    'native cancellation and setup errors reach the correct UI phase',
    () async {
      for (final message in [
        'Pairing cancelled.',
        'Accessory setup was interrupted.',
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'ask_picker', message: message);
        });
        await expectLater(
          AccessorySetup.showPicker(),
          throwsA(
            isA<PlatformException>().having(
              classifyPairError,
              'pairing phase',
              message.contains('cancelled')
                  ? PairPhase.cancelled
                  : PairPhase.failed,
            ),
          ),
        );
      }
    },
  );

  testWidgets(
    'localized Bluetooth blocker does not claim a global radio outage',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingView(
            phase: PairPhase.bluetoothBlocked,
            blocker: BleBlocker.adapterOff,
            onPair: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Bluetooth is unavailable to OpenStrap'),
        findsOneWidget,
      );
      expect(find.textContaining('no accessory is authorized'), findsOneWidget);
      expect(find.textContaining('cannot be reached by any app'), findsNothing);
      expect(
        find.textContaining('if it is on, pair your band here'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'setup failure shows the actual error without claiming discovery',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingView(
            phase: PairPhase.failed,
            detail: 'Accessory setup was interrupted.',
            onPair: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Accessory setup was interrupted.'), findsOneWidget);
      expect(find.textContaining('The band was reachable'), findsNothing);
      expect(
        find.textContaining('Scanning again from a metre away'),
        findsNothing,
      );
      expect(find.text('Band setup did not complete'), findsOneWidget);
    },
  );
}
