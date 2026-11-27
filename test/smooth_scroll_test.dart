import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sable/ui/widgets.dart';

void main() {
  testWidgets('wheel notches glide and pile up', (t) async {
    final c = SmoothScroll();
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ListView.builder(controller: c, itemExtent: 50, itemCount: 1000, itemBuilder: (_, i) => Text('$i')),
    ));
    final p = t.getCenter(find.byType(ListView));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(mouse.hover(p));
    await t.sendEventToBinding(mouse.scroll(const Offset(0, 50)));
    await t.pump(const Duration(milliseconds: 16));
    final early = c.offset;
    await t.pump(const Duration(milliseconds: 16));
    expect(c.offset, greaterThan(early)); // still moving: a glide, not a jump
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(c.offset, closeTo(110, 1));
    // Ten quick notches go ten times as far.
    for (var i = 0; i < 10; i++) {
      await t.sendEventToBinding(mouse.scroll(const Offset(0, 50)));
      await t.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(c.offset, closeTo(1210, 2));
    await t.pump(const Duration(milliseconds: 400)); // the "still wheeling" moment ends
  });
}
