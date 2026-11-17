import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/probe_page.dart';

void main() {
  testWidgets('P0 screen shows public fixture controls', (tester) async {
    await tester.pumpWidget(const WencryptProbeApp());
    expect(find.text('Wencrypt P0'), findsOneWidget);
    expect(find.text('验证 Rust 加密与解锁耗时'), findsOneWidget);
    expect(find.text('验证仅使用公开测试数据'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
  });
}
