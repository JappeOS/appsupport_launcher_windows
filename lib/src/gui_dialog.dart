import 'dart:convert';
import 'dart:io';

class GuiDialog {
  final GuiDialogType type;
  final String text;
  final bool progressIntermediate;

  late Future<Process> _future;

  factory GuiDialog.progress(
    String text, {
    bool intermediate = true,
  }) => GuiDialog._(
    type: GuiDialogType.progress,
    text: text,
    progressIntermediate: intermediate,
  );

  factory GuiDialog.error(
    String error,
  ) => GuiDialog._(
    type: GuiDialogType.error,
    text: error,
  );

  GuiDialog._({
    required this.type,
    required this.text,
    this.progressIntermediate = true,
  }) {
    List<String> args;
    switch (type) {
      case GuiDialogType.progress:
        args = [
          '--progress',
          if (progressIntermediate)
            '--pulsate',
          '--no-cancel',
          '--text=$text',
        ];
        break;
      case GuiDialogType.error:
        args = [
          '--error',
          '--text=$text',
        ];
      // ignore: unreachable_switch_default
      default: throw Exception("Unknown dialog type.");
    }

    _future = Process.start('zenity', args);
  }

  Future<void> updateProgress({int? percentage, String? message}) async {
    assert(
      percentage != null || message != null,
      "Either percentage or message must contain a non-null value.",
    );

    final process = await _future;
    process.stdin.encoding = utf8;
    if (percentage != null) {
      process.stdin.writeln(percentage.toString());
    }
    if (message != null) {
      process.stdin.writeln("#$message");
    }
  }

  Future<void> close([bool wait = false]) async {
    try {
      final process = await _future;
      process.kill();
      if (wait) {
        await process.exitCode;
      }
    } catch (e) {
      print("Failed to display or close wait dialog: $e");
    }
  }

  Future<int> result() async {
    final process = await _future;
    return await process.exitCode;
  }
}

enum GuiDialogType {
  progress,
  error,
}