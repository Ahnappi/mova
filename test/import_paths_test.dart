// 相对导入的层级守卫。
//
// 手抄 `../../../` 这种路径，多写或少写一层是最容易犯的错：
// 文件照样能保存、IDE 也不一定立刻报错，直到整包编译才炸。
// 而且它专挑**新加的文件**出错——新目录深一层，路径是从别处复制来的。
//
// 这里把 lib 与 test 下所有 `import / export / part` 的相对路径都解析一遍，
// 落到不存在的文件就失败。这样以后再写错，是在这条用例里报错，
// 而不是等到 `flutter build` 才发现。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('每个相对导入都指向一个真实存在的文件', () {
    final root = Directory.current.path;
    final problems = <String>[];

    for (final name in const ['lib', 'test']) {
      final directory = Directory(p.join(root, name));
      if (!directory.existsSync()) continue;

      for (final entity
          in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;

        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final match = RegExp(
            r"^\s*(?:import|export|part)\s+'(\.[^']+)'",
          ).firstMatch(lines[i]);
          if (match == null) continue;

          final spec = match.group(1)!;
          final resolved =
              p.normalize(p.join(p.dirname(entity.path), spec));
          final where = '${p.relative(entity.path, from: root)}:${i + 1}';

          if (!File(resolved).existsSync()) {
            problems.add('$where 导入 $spec，但它指向的文件不存在'
                '（解析为 ${p.relative(resolved, from: root)}）');
          } else if (!p.isWithin(root, resolved)) {
            problems.add('$where 导入 $spec，跑出了项目目录');
          }
        }
      }
    }

    expect(
      problems,
      isEmpty,
      reason: '相对导入的层级写错了（多半是多退或少退了一层 ../）：\n'
          '${problems.join('\n')}',
    );
  });
}
