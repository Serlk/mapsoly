import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

/// The app routes hardware "back" keys to `Navigator.maybePop`, and screens
/// answer through `PopScope`. This checks that wiring in isolation.
void main() {
  testWidgets('the back key reaches PopScope and closes pushed pages', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var open = true; // something the screen can close
    var handled = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.goBack): () =>
                navigator.currentState?.maybePop(),
            const SingleActivator(LogicalKeyboardKey.browserBack): () =>
                navigator.currentState?.maybePop(),
          },
          child: child!,
        ),
        home: StatefulBuilder(
          builder: (context, setState) => PopScope(
            canPop: !open,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                handled++;
                setState(() => open = false);
              }
            },
            child: const Focus(autofocus: true, child: Scaffold()),
          ),
        ),
      ),
    );
    await tester.pump();

    // The key bindings end in Navigator.maybePop; the test harness cannot
    // simulate the phone's "Go Back" key, so that call is made directly.
    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(handled, 1);
    expect(open, isFalse);

    // A pushed page is closed by the same key.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Focus(autofocus: true, child: Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(navigator.currentState!.canPop(), isTrue);
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(navigator.currentState!.canPop(), isFalse);
    expect(handled, 1);
  });
}
