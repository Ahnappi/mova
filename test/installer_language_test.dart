// Windows 安装程序的中文语言文件：必须随仓库走，不能指望 CI 机器预装。
//
// 两条容易悄悄退化的规则：
// 1. `[Languages]` 里中文那行如果写回 `compiler:Languages\ChineseSimplified.isl`，
//    就是把「这台机器正好装了中文语言包」当前提——中文不是 Inno Setup
//    的默认语言，精简安装 / 换一个 Runner 上就编不过（或静默退回英文）；
// 2. 语言文件本身可能「下错东西」：把 GitHub 的网页 HTML 当成原始文件存下来，
//    文件存在、大小也不小，但编译时报一堆看不懂的错。
//
// 英文那条保持 `compiler:Default.isl`：它是编译器自带的、一定存在，
// 复制一份进仓库反而多一份要跟着升级的东西。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final iss = File(p.join('installers', 'windows', 'mova.iss'));
  final isl =
      File(p.join('installers', 'windows', 'Languages', 'ChineseSimplified.isl'));

  test('安装脚本使用仓库内的中文语言文件', () {
    expect(iss.existsSync(), isTrue, reason: '测试需要在项目根目录运行');

    final text = iss.readAsStringSync();
    expect(
      text,
      contains(r'MessagesFile: "Languages\ChineseSimplified.isl"'),
      reason: '中文应指向 installers/windows/Languages/ 下的文件，'
          '不能依赖编译器自带目录里有没有中文包',
    );
    expect(
      text,
      isNot(contains(r'compiler:Languages\ChineseSimplified.isl')),
      reason: '这一行一旦改回 compiler:，CI 换台机器就可能编不过',
    );
    expect(
      text,
      contains(r'MessagesFile: "compiler:Default.isl"'),
      reason: '英文仍用编译器自带文件，不必复制进仓库',
    );
  });

  test('中文语言文件存在，且是真正的 .isl 而不是网页', () {
    expect(isl.existsSync(), isTrue, reason: '语言文件必须随仓库走');

    final text = isl.readAsStringSync();
    expect(
      text.replaceAll('\r', ''),
      isNot(contains('<!DOCTYPE html')),
      reason: '像是把 GitHub 网页存下来了：要存原始文件，不是页面',
    );
    // 原始文件开头是一段 ; 注释，写着为哪个 Inno Setup 版本而作。
    expect(
      text.startsWith('; *** Inno Setup'),
      isTrue,
      reason: '文件头不对，多半下到的不是原始 .isl',
    );
    expect(text, contains('[LangOptions]'));
    expect(text, contains('[Messages]'));
    expect(text, contains('LanguageName=简体中文'));
    expect(
      text,
      contains('LanguageID=\$0804'),
      reason: '简体中文的 LCID 是 \$0804',
    );
  });
}
