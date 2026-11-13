import 'package:flutter/material.dart';

/// The app's [ScaffoldMessenger], set up so that messages with an action
/// (Undo) still close after their time while an accessibility service is
/// on. Flutter keeps such a message up until it is tapped whenever any
/// accessibility service runs, including ones that only automate taps, so
/// it stayed over every page and could be tapped by accident.
///
/// Only the messenger, which runs the close timer, sees accessible
/// navigation as off; everything below it gets the real setting back.
class TimedSnackBars extends StatelessWidget {
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  final Widget child;

  const TimedSnackBars({super.key, this.messengerKey, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(accessibleNavigation: false),
      child: ScaffoldMessenger(
        key: messengerKey,
        child: MediaQuery(data: media, child: child),
      ),
    );
  }
}
