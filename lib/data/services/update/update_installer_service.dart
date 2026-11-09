import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';

import '../../../domain/models/update/app_update.dart';

/// 系统层：流式下载、准备替换目录、启动独立安装进程。
class UpdateInstallerService {
  final Logger _log = Logger('UpdateInstallerService');
  HttpClient? _client;
  bool _cancelled = false;

  String get platformKey {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isMacOS) {
      // 当前发布流水线只提供 Apple Silicon 产物。
      return 'macos-arm64';
    }
    throw UnsupportedError('当前平台暂不支持自动更新');
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<File> download(UpdateAsset asset, void Function(double?) progress) async {
    _cancelled = false;
    final directory = await Directory.systemTemp.createTemp('mova-update-');
    final file = File(p.join(directory.path, Platform.isWindows ? 'setup.exe' : 'update.zip'));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(asset.url)).timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      if (response.contentLength > 0 && response.contentLength != asset.size) {
        throw const FormatException('安装包大小与发布清单不一致');
      }
      sink = file.openWrite();
      // 同时观察输出错误，避免文件写入异常成为未处理 Future。
      final outputDone = sink.done.then<Object?>((_) => null, onError: (Object e) => e);
      var received = 0;
      final progressClock = Stopwatch()..start();
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw const FormatException('已取消更新下载');
        received += bytes.length;
        if (received > asset.size) throw const FormatException('安装包超过声明大小');
        sink.add(bytes);
        await sink.flush();
        if (progressClock.elapsedMilliseconds >= 100 || received == asset.size) {
          progress(received / asset.size);
          progressClock.reset();
        }
      }
      await sink.close();
      sink = null;
      final outputError = await outputDone;
      if (outputError != null) throw FileSystemException('写入更新包失败：$outputError');
      if (_cancelled || received != asset.size) throw const FormatException('安装包下载不完整');
      return file;
    } catch (_) {
      try { await sink?.close(); } catch (_) {}
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  /// 返回启动函数；准备阶段出错不会退出当前 App。
  Future<Future<void> Function()> prepare(File package) async {
    final executable = Platform.resolvedExecutable;
    final ready = File(p.join(package.parent.path, 'ready'));
    if (Platform.isWindows) {
      if (p.basename(executable).toLowerCase() != 'mova.exe') {
        throw StateError('请在安装后的 mova 中执行更新');
      }
      final script = File(p.join(package.parent.path, 'install.ps1'));
      await script.writeAsString(r'''
param([int]$ParentId, [string]$Installer, [string]$AppExe, [string]$Ready)
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $Ready -Value 'ready'
try {
  $parent = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
  if ($parent -and -not $parent.WaitForExit(120000)) { exit 1 }
  $dir = Split-Path -Parent $AppExe
  $argsList = @('/SP-', '/SILENT', '/NORESTART', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', ('/DIR="' + $dir + '"'), '/LOG')
  $installerProcess = Start-Process -FilePath $Installer -ArgumentList $argsList -Verb RunAs -Wait -PassThru
  if ($installerProcess.ExitCode -ne 0) { throw "Installer exit code: $($installerProcess.ExitCode)" }
} catch {
  $_ | Out-File -LiteralPath ($Ready + '.error')
} finally {
  if (-not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $AppExe
  }
}
''');
      return () => _startHelper('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path,
        '-ParentId', '$pid', '-Installer', package.path, '-AppExe', executable, '-Ready', ready.path], ready);
    }
    if (!Platform.isMacOS) throw UnsupportedError('当前平台暂不支持自动更新');
    final arch = await Process.run('/usr/bin/uname', ['-m']);
    if (arch.stdout.toString().trim() != 'arm64') throw UnsupportedError('当前只发布 Apple Silicon 更新包');
    final app = Directory(p.dirname(p.dirname(p.dirname(executable))));
    if (!app.path.endsWith('.app') || app.path.startsWith('/Volumes/')) {
      throw StateError('请先将 mova 安装到本机可写目录，再执行更新');
    }
    final staging = await app.parent.createTemp('.mova-update-');
    try {
      final extract = Directory(p.join(package.parent.path, 'extracted'));
      await extract.create();
      final result = await Process.run('/usr/bin/ditto', ['-x', '-k', package.path, extract.path]);
      if (result.exitCode != 0) throw StateError('解压更新失败：${result.stderr}');
      final source = Directory(p.join(extract.path, 'mova.app'));
      if (!await File(p.join(source.path, 'Contents/MacOS/mova')).exists()) {
        throw const FormatException('更新包不包含 mova.app');
      }
      final next = p.join(staging.path, 'new.app');
      final copy = await Process.run('/usr/bin/ditto', [source.path, next]);
      if (copy.exitCode != 0) throw StateError('准备新版 App 失败：${copy.stderr}');
      final script = File(p.join(package.parent.path, 'install.sh'));
      await script.writeAsString(r'''#!/bin/bash
set -eu
parent="$1"; target="$2"; stage="$3"; ready="$4"
printf ready > "$ready"
for ((i=0; i<120; i++)); do
  if ! kill -0 "$parent" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$parent" 2>/dev/null; then exit 1; fi
exec >> "${ready}.log" 2>&1
if mv "$target" "$stage/previous.app"; then
  if ! mv "$stage/new.app" "$target"; then
    mv "$stage/previous.app" "$target"
  fi
fi
/usr/bin/open "$target"
''');
      return () => _startHelper('/bin/bash', [script.path, '$pid', app.path, staging.path, ready.path], ready);
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _startHelper(String executable, List<String> args, File ready) async {
    if (await ready.exists()) await ready.delete();
    final clock = Stopwatch()..start();
    _log.info('辅助进程：开始启动 $executable，ready=${ready.path}');
    final helper = await Process.start(executable, args, mode: ProcessStartMode.detached);
    _log.info('辅助进程：已创建 pid=${helper.pid}，耗时 ${clock.elapsedMilliseconds}ms');
    for (var i = 0; i < 50; i++) {
      if (await ready.exists()) {
        _log.info('辅助进程：ready 已出现，耗时 ${clock.elapsedMilliseconds}ms');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _log.warning('辅助进程：等待 ready 超时，耗时 ${clock.elapsedMilliseconds}ms');
    Process.killPid(helper.pid);
    throw StateError('更新辅助进程未能启动，请重启 App 后重试');
  }
}
