import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// 一次「原子提交」的结果。
///
/// [ok] 为真表示新名字已经挂上；否则看 [error]。
/// 注意这里**不带**「目标已存在」这个分支：是否算冲突由调用方
/// 看路径上有没有东西来决定（拿不到 errno，判断存在性更可靠）。
typedef AtomicCommitResult = ({bool ok, Object? error});

typedef _NativePosixLink = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _DartPosixLink = int Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _NativeWinLink = Int32 Function(
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Void>,
);
typedef _DartWinLink = int Function(
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Void>,
);

typedef _NativeMalloc = Pointer<Void> Function(IntPtr);
typedef _DartMalloc = Pointer<Void> Function(int);
typedef _NativeFree = Void Function(Pointer<Void>);
typedef _DartFree = void Function(Pointer<Void>);

/// 平台提供的「不替换目标的原子提交」原语（硬链接）。
///
/// 为什么不能用 `File.rename`：
/// POSIX 的 `rename()` 在目标已存在时是**静默替换**，Windows 的
/// `MoveFileEx(REPLACE_EXISTING)` 同样如此。于是「先检查目标在不在、
/// 再改名」这种写法永远挡不住并发——检查与改名之间隔着一次 await，
/// 别的程序完全可能在这个窗口里放一个同名文件进来，然后被我们覆盖掉。
/// 先 `create(exclusive: true)` 占位也一样：那只能保证「创建那一刻」
/// 没有冲突，之后那条路径照样可能被别人替换，随后的普通改名还是会
/// 覆盖它（而且「目标现在是 0 字节」并不能证明它属于本次接收）。
///
/// 硬链接（POSIX `link` / Windows `CreateHardLink`）相反：
/// 目标已存在时必定失败，而且「检查」与「创建」是**同一个系统调用**，
/// 中间没有任何窗口。这是各桌面平台都支持的、唯一能保证
/// 「要么拿到新名字，要么明确失败，绝不替换已有文件」的提交方式。
///
/// 拿不到这个能力时（平台不支持、文件系统不支持——例如 exFAT/FAT，
/// 或权限不足）一律**明确报错**，绝不退回会覆盖目标的普通改名：
/// 给用户一个错误提示，远比悄悄覆盖掉他已有的文件要好。
abstract final class AtomicLink {
  AtomicLink._();

  static bool _resolved = false;
  static _DartPosixLink? _posixLink;
  static _DartWinLink? _winLink;
  static _DartMalloc? _malloc;
  static _DartFree? _free;
  static Object? _error;

  /// 当前平台能不能用（只解析符号，不碰文件系统）。
  static bool get isAvailable {
    _resolve();
    return _posixLink != null || _winLink != null;
  }

  /// 解析失败的原因（[isAvailable] 为 false 时才有值）。
  static Object? get resolveError {
    _resolve();
    return _error;
  }

  /// 给 [existingPath] 再挂一个名字 [newPath]。
  ///
  /// [newPath] 已存在时必定失败，且**不会动**那个已存在的文件。
  static AtomicCommitResult create(String existingPath, String newPath) {
    _resolve();

    final posix = _posixLink;
    if (posix != null) return _createPosix(posix, existingPath, newPath);

    final windows = _winLink;
    if (windows != null) return _createWindows(windows, existingPath, newPath);

    return (
      ok: false,
      error: _error ?? Exception('当前平台不支持不覆盖的原子提交'),
    );
  }

  static AtomicCommitResult _createPosix(
    _DartPosixLink link,
    String existingPath,
    String newPath,
  ) {
    final existing = _cString(existingPath);
    final target = _cString(newPath);
    if (existing == null || target == null) {
      _release(existing);
      _release(target);
      return (ok: false, error: Exception('提交时无法为路径分配内存'));
    }
    try {
      final code = link(existing, target);
      if (code == 0) return (ok: true, error: null);
      return (
        ok: false,
        error: Exception(
          '原子提交失败（$existingPath → $newPath）：系统返回 $code',
        ),
      );
    } catch (e) {
      return (ok: false, error: e);
    } finally {
      _release(existing);
      _release(target);
    }
  }

  static AtomicCommitResult _createWindows(
    _DartWinLink link,
    String existingPath,
    String newPath,
  ) {
    final existing = _utf16(existingPath);
    final target = _utf16(newPath);
    if (existing == null || target == null) {
      _release(existing);
      _release(target);
      return (ok: false, error: Exception('提交时无法为路径分配内存'));
    }
    try {
      // CreateHardLinkW(新名字, 已有文件, 安全属性=null)。
      final code = link(target, existing, Pointer<Void>.fromAddress(0));
      if (code != 0) return (ok: true, error: null);
      return (
        ok: false,
        error: Exception('原子提交失败（$existingPath → $newPath）'),
      );
    } catch (e) {
      return (ok: false, error: e);
    } finally {
      _release(existing);
      _release(target);
    }
  }

  static void _resolve() {
    if (_resolved) return;
    _resolved = true;
    try {
      final library = _openSystemLibrary();
      _malloc = library.lookupFunction<_NativeMalloc, _DartMalloc>('malloc');
      _free = library.lookupFunction<_NativeFree, _DartFree>('free');
      if (Platform.isWindows) {
        _winLink = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_NativeWinLink, _DartWinLink>('CreateHardLinkW');
      } else {
        _posixLink =
            library.lookupFunction<_NativePosixLink, _DartPosixLink>('link');
      }
    } catch (e) {
      _error = e;
      _posixLink = null;
      _winLink = null;
    }
  }

  /// 打开系统 C 库：优先按名字打开，最后退回进程自身的全局符号表
  /// （libc 的符号本来就在里面）。
  static DynamicLibrary _openSystemLibrary() {
    final names = <String>[
      if (Platform.isMacOS) ...const ['/usr/lib/libSystem.dylib', 'libSystem.dylib'],
      if (Platform.isLinux) ...const ['libc.so.6', 'libc.so'],
      if (Platform.isWindows) ...const ['msvcrt.dll'],
    ];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        // 换下一个候选。
      }
    }
    return DynamicLibrary.process();
  }

  static Pointer<Uint8>? _cString(String value) {
    final units = utf8.encode(value);
    final pointer = _allocate(units.length + 1)?.cast<Uint8>();
    if (pointer == null) return null;
    for (var i = 0; i < units.length; i++) {
      (pointer + i).value = units[i];
    }
    (pointer + units.length).value = 0;
    return pointer;
  }

  static Pointer<Uint16>? _utf16(String value) {
    // Dart 字符串的 codeUnits 本身就是 UTF-16 码元，正好是 Windows 要的。
    final units = value.codeUnits;
    final pointer = _allocate((units.length + 1) * 2)?.cast<Uint16>();
    if (pointer == null) return null;
    for (var i = 0; i < units.length; i++) {
      (pointer + i).value = units[i];
    }
    (pointer + units.length).value = 0;
    return pointer;
  }

  static Pointer<Void>? _allocate(int bytes) {
    final allocate = _malloc;
    if (allocate == null) return null;
    final pointer = allocate(bytes);
    // malloc 失败返回 NULL：往 0 地址写会直接崩掉进程，必须先挡住。
    if (pointer.address == 0) return null;
    return pointer;
  }

  static void _release(Pointer<NativeType>? pointer) {
    if (pointer == null || pointer.address == 0) return;
    _free?.call(pointer.cast<Void>());
  }
}
