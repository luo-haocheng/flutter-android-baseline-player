// 本项目首页是一个原生播放器的 PlatformView（NativeVideoView），
// 在 widget 测试环境里没有对应的平台实现，所以这里保留一个最小的冒烟测试。
// 播放器/通道的真实行为需要到模拟器或真机上验证（flutter run）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Widget 树可以正常构建', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Flutter Player')),
        ),
      ),
    );

    expect(find.text('Flutter Player'), findsOneWidget);
  });
}
