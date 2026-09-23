/// 结果封装工具（参照 compass_app 的错误处理约定）。
///
/// 用 switch 处理结果，强制调用方处理成功与失败两种分支：
/// ```dart
/// switch (result) {
///   case Ok(): print(result.value);
///   case Error(): print(result.error);
/// }
/// ```
sealed class Result<T> {
  const Result();

  /// 成功结果，携带 [value]。
  const factory Result.ok(T value) = Ok._;

  /// 失败结果，携带 [error]。
  const factory Result.error(Exception error) = Error._;
}

/// [Result] 的成功子类。
final class Ok<T> extends Result<T> {
  const Ok._(this.value);

  /// 成功时返回的值。
  final T value;

  @override
  String toString() => 'Result<$T>.ok($value)';
}

/// [Result] 的失败子类。
final class Error<T> extends Result<T> {
  const Error._(this.error);

  /// 失败时返回的错误。
  final Exception error;

  @override
  String toString() => 'Result<$T>.error($error)';
}
