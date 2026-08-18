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
/// Light keeps the tonal [secondaryContainer] blend. Dark uses a dedicated
/// action fill so primary confirms stay visible on warm surfaces.
ButtonStyle kiduDialogPrimaryButtonStyle(BuildContext context) {
  return _kiduPrimaryActionButtonStyle(context);
}

/// Softer [FilledButton] style for KiDu form-card primary actions.
ButtonStyle kiduFormPrimaryButtonStyle(BuildContext context) {
  return _kiduPrimaryActionButtonStyle(context);
}

ButtonStyle _kiduPrimaryActionButtonStyle(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  if (cs.brightness == Brightness.dark) {
    return FilledButton.styleFrom(
      backgroundColor: const Color(0xFF3B6476),
      foregroundColor: const Color(0xFFD4ECF5),
    );
  }
  final background = Color.alphaBlend(
    cs.onSecondaryContainer.withValues(alpha: 0.10),
    cs.secondaryContainer,
  );
  return FilledButton.styleFrom(
    backgroundColor: background,
    foregroundColor: cs.onSecondaryContainer,
  );
}

/// Extra dark-mode alpha on top of a destructive light-path alpha.
const double kiduDestructiveDarkAlphaLift = 0.18;

/// Dark-only destructive user-action foreground. Not [ColorScheme.error].
const Color kiduDestructiveDarkForeground = Color(0xFFD87878);

/// Destructive-action alpha. Light keeps [lightAlpha]; dark lifts it.
double kiduDestructiveAlpha(BuildContext context, double lightAlpha) {
  if (Theme.of(context).brightness != Brightness.dark) return lightAlpha;
  final lifted = lightAlpha + kiduDestructiveDarkAlphaLift;
  return lifted > 1.0 ? 1.0 : lifted;
}

/// Destructive user-action foreground (delete buttons/icons).
///
/// Light uses [ColorScheme.error] at [lightAlpha]. Dark uses
/// [kiduDestructiveDarkForeground] at the lifted alpha. Validation and
/// generic error copy should keep using the scheme token directly.
Color kiduDestructiveForeground(BuildContext context, double lightAlpha) {
  final alpha = kiduDestructiveAlpha(context, lightAlpha);
  final base = Theme.of(context).brightness == Brightness.dark
      ? kiduDestructiveDarkForeground
      : Theme.of(context).colorScheme.error;
  return base.withValues(alpha: alpha);
}
