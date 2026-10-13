import 'package:flutter/material.dart';

/// Card-isolate bootstrap (`askLocalCardMain`): rendered by the overlay
/// window's secondary engine (see AskLocalOverlayWindow.kt). Task 3 ships
/// only the dialog-style progress placeholder — the window must show
/// SOMETHING on the first frame; Task 4's card notifier materializes the
/// full fork-panel card in this isolate.
void askLocalCardMain() {
  runApp(const _AskLocalCardProgress());
}

class _AskLocalCardProgress extends StatelessWidget {
  const _AskLocalCardProgress();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: const Color(0xF2FAFAFA),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(28),
        child: const CircularProgressIndicator(
          key: Key('ask_local_card_progress'),
          strokeWidth: 3,
        ),
      ),
    );
  }
}
