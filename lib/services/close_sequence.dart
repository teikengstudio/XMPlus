import "app_log.dart";

/// Releases resources in order, retaining the failed step for an explicit retry.
/// Successful steps must never run again after their resources have been closed.
class CloseSequence {
  CloseSequence(List<Future<void> Function()> steps)
    : _steps = List.unmodifiable(steps) {
    AppLog.instance.trace(
      "lib/services/close_sequence.dart::CloseSequence.new",
    );
  }

  final List<Future<void> Function()> _steps;
  int _next = 0;
  Future<void>? _running;

  Future<void> run() {
    AppLog.instance.trace(
      "lib/services/close_sequence.dart::CloseSequence.run",
    );
    return _running ??= _run().whenComplete(() {
      AppLog.instance.trace(
        "lib/services/close_sequence.dart::CloseSequence.run.closure#1",
      );

      _running = null;
    });
  }

  Future<void> _run() async {
    AppLog.instance.trace(
      "lib/services/close_sequence.dart::CloseSequence._run",
    );

    while (_next < _steps.length) {
      await _steps[_next]();
      _next++;
    }
  }
}
