import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/qr_code.dart';

void main() {
  test('encodes short and long URIs with valid finder and timing patterns', () {
    final shortMatrix = QrMatrix.encode('wencrypt://join?v=2&lan=test123');
    expect(shortMatrix.version, greaterThanOrEqualTo(1));
    expect(shortMatrix.size, shortMatrix.version * 4 + 17);
    // Top-left finder corners and center.
    expect(shortMatrix.isDark(0, 0), isTrue);
    expect(shortMatrix.isDark(1, 1), isFalse);
    expect(shortMatrix.isDark(3, 3), isTrue);
    expect(shortMatrix.isDark(6, 6), isTrue);
    // Dark module.
    expect(shortMatrix.isDark(8, shortMatrix.version * 4 + 9), isTrue);

    final lanPayload =
        'wencrypt://join?v=2&lan=${'A' * 160}';
    final lanMatrix = QrMatrix.encode(lanPayload);
    expect(lanMatrix.version, greaterThanOrEqualTo(7));
    expect(lanMatrix.size, lanMatrix.version * 4 + 17);

    final invitePayload =
        'wencrypt://join?v=2&p=${'B' * 520}';
    final inviteMatrix = QrMatrix.encode(invitePayload);
    expect(inviteMatrix.version, lessThanOrEqualTo(20));
    expect(inviteMatrix.size, inviteMatrix.version * 4 + 17);
  });

  test('falls back to low ECC for large payloads near capacity', () {
    final nearMax = 'wencrypt://join?v=2&p=${'C' * 800}';
    final matrix = QrMatrix.encode(nearMax);
    expect(matrix.ecc, QrErrorCorrection.low);
    expect(matrix.version, lessThanOrEqualTo(20));

    expect(() => QrMatrix.encode('x' * 900), throwsArgumentError);
  });

  testWidgets('WQrCode renders without error', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: WQrCode(data: 'wencrypt://join?v=2&lan=fixture', size: 220),
          ),
        ),
      ),
    );
    expect(find.byType(WQrCode), findsOneWidget);
  });
}
