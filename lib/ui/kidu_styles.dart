import 'package:flutter/material.dart';

/// KiDu AppBar/card title style for action-dialog titles.
Widget kiduActionDialogTitle(BuildContext context, String text) {
  return Text(
    text,
    style: Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    ),
  );
}

/// Compact [InputDecoration] for action-dialog form fields (dense + padding).
InputDecoration kiduCompactInputDecoration({
  required String labelText,
  String? hintText,
  Widget? suffixIcon,
  Widget? prefixIcon,
  String? helperText,
  String? errorText,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    helperText: helperText,
    errorText: errorText,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  );
}

/// Softer [FilledButton] style for KiDu action-dialog primary actions.
///
/// Tonal base ([secondaryContainer]) with a subtle blend toward
/// [onSecondaryContainer] for more presence without full primary fill.
ButtonStyle kiduDialogPrimaryButtonStyle(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final background = Color.alphaBlend(
    cs.onSecondaryContainer.withValues(alpha: 0.10),
    cs.secondaryContainer,
  );
  return FilledButton.styleFrom(
    backgroundColor: background,
    foregroundColor: cs.onSecondaryContainer,
  );
}

/// Softer [FilledButton] style for KiDu form-card primary actions.
ButtonStyle kiduFormPrimaryButtonStyle(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final background = Color.alphaBlend(
    cs.onSecondaryContainer.withValues(alpha: 0.10),
    cs.secondaryContainer,
  );
  return FilledButton.styleFrom(
    backgroundColor: background,
    foregroundColor: cs.onSecondaryContainer,
  );
}
