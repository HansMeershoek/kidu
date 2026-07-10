/// Small, reusable read-only UI building blocks shared across screens.
///
/// Fase 1 scope: these widgets only *display* the read-only state. They are
/// intentionally free of Firestore/Auth logic and of snackbars — callers
/// decide when to show them (typically: `if (isReadOnly) ...`).
library;

import 'package:flutter/material.dart';

/// Short label used wherever screen space is tight (under an AppBar title).
const String readOnlyLabel = 'Read-only';

/// Longer explanation used where there is room for a full sentence (banners,
/// screen bodies).
const String readOnlyExplanation =
    'Dit huishouden is beëindigd. Je kunt bestaande gegevens bekijken en '
    'exporteren, maar niets meer toevoegen of wijzigen.';

/// Small, quiet "Read-only" label. Meant to sit directly under a screen
/// title (e.g. inside an AppBar's `title`, or at the top of a screen body).
class ReadOnlyBadge extends StatelessWidget {
  const ReadOnlyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      readOnlyLabel,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

/// Wraps an existing AppBar title widget and, when [isReadOnly] is true,
/// adds a small [ReadOnlyBadge] directly underneath it.
///
/// Usage: `title: ReadOnlyAppBarTitle(isReadOnly: isReadOnly, title: Text('KiDu'))`.
class ReadOnlyAppBarTitle extends StatelessWidget {
  const ReadOnlyAppBarTitle({
    super.key,
    required this.title,
    required this.isReadOnly,
  });

  final Widget title;
  final bool isReadOnly;

  @override
  Widget build(BuildContext context) {
    if (!isReadOnly) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [title, const SizedBox(height: 4), const ReadOnlyBadge()],
    );
  }
}

/// Static explanation banner for screen bodies (no snackbar). Meant to be
/// placed at the top of scrollable content, above any list/form.
class ReadOnlyExplanationBanner extends StatelessWidget {
  const ReadOnlyExplanationBanner({
    super.key,
    this.text = readOnlyExplanation,
    this.padding = const EdgeInsets.only(bottom: 16),
  });

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.35,
        ),
      ),
    );
  }
}
