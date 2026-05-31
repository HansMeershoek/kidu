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

/// Central input corner radius — adjust here to soften or tighten all KiDu inputs.
const double kiduInputBorderRadius = 12.0;

/// Neutral outline alpha for inactive/default input borders.
const double kiduInputBorderOutlineAlpha = 0.50;

/// Neutral outline alpha for active/focused input borders.
const double kiduInputBorderFocusedOutlineAlpha = 1.0;

OutlineInputBorder _kiduOutlineInputBorder({
  required Color outlineColor,
  double width = 1.0,
}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(kiduInputBorderRadius),
    borderSide: BorderSide(color: outlineColor, width: width),
  );
}

/// Compact [InputDecoration] for action-dialog form fields (dense + padding).
InputDecoration kiduCompactInputDecoration({
  required BuildContext context,
  required String labelText,
  String? hintText,
  Widget? suffixIcon,
  Widget? prefixIcon,
  String? helperText,
  String? errorText,
}) {
  final outline = Theme.of(context).colorScheme.outline;
  final enabledOutline = outline.withValues(
    alpha: kiduInputBorderOutlineAlpha,
  );
  final focusedOutline = outline.withValues(
    alpha: kiduInputBorderFocusedOutlineAlpha,
  );
  final enabledBorder = _kiduOutlineInputBorder(outlineColor: enabledOutline);
  final focusedBorder = _kiduOutlineInputBorder(outlineColor: focusedOutline);

  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    helperText: helperText,
    errorText: errorText,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    border: enabledBorder,
    enabledBorder: enabledBorder,
    focusedBorder: focusedBorder,
    errorBorder: enabledBorder,
    focusedErrorBorder: focusedBorder,
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
