import 'dart:io';

class GuiDialog {
  final GuiDialogType type;
  final String text;
  late Future<Process> _future;

  factory GuiDialog.progress(
    String text,
  ) => GuiDialog._(
    type: GuiDialogType.progress,
    text: text,
  );

  factory GuiDialog.error(
    String error,
  ) => GuiDialog._(
    type: GuiDialogType.error,
    text: error,
  );

  GuiDialog._({required this.type, required this.text}) {
    List<String> args;
    switch (type) {
      case GuiDialogType.progress:
        args = [
          '--progress',
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