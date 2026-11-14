/// The app's look: colours, fonts and the styling of every standard
/// component (cards, buttons, inputs, sheets, navigation). Screens take
/// their style from here, so change the look in this one place.
///
/// The palette is deliberately three colours: black, white and ONE accent
/// (the phone's own theme colour where the phone provides one). Greys are
/// just black/white at different strengths. Green and red appear only to
/// mean "correct" and "wrong".
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class AppColors {
  /// Accent used when the phone does not offer a theme colour.
  static const Color accentDark = Color(0xFFA99BFF);
  static const Color accentLight = Color(0xFF5B45E0);

  /// Meaning-only colours: correct / wrong.
  static const Color success = Color(0xFF30D158);
  static const Color danger = Color(0xFFFF453A);
}

class AppTheme {
  static const String display = 'Outfit';
  static const String body = 'PlusJakartaSans';

  /// Black theme. [accent] is the phone's theme colour, if it has one.
  static ThemeData dark([Color? accent]) => _build(
    brightness: Brightness.dark,
    background: Colors.black,
    surface: const Color(0xFF0C0C0E),
    surfaceHigh: const Color(0xFF17171A),
    outline: const Color(0xFF26262A),
    primary: accent ?? AppColors.accentDark,
    text: const Color(0xFFF5F5F7),
    muted: const Color(0xFF8E8E93),
  );

  /// White theme.
  static ThemeData light([Color? accent]) => _build(
    brightness: Brightness.light,
    background: Colors.white,
    surface: const Color(0xFFF6F6F8),
    surfaceHigh: const Color(0xFFECECEF),
    outline: const Color(0xFFE2E2E6),
    primary: accent ?? AppColors.accentLight,
    text: const Color(0xFF0A0A0A),
    muted: const Color(0xFF6E6E73),
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color surfaceHigh,
    required Color outline,
    required Color primary,
    required Color text,
    required Color muted,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: background,
          secondary: primary,
          tertiary: AppColors.success,
          error: AppColors.danger,
          surface: background,
          onSurface: text,
          onSurfaceVariant: muted,
          surfaceContainerLowest: background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: surfaceHigh,
          surfaceContainerHighest: surfaceHigh,
          outline: outline,
          outlineVariant: outline,
          secondaryContainer: primary.withValues(alpha: isDark ? 0.22 : 0.14),
          onSecondaryContainer: text,
        );

    final base = ThemeData(
      colorScheme: scheme,
      fontFamily: body,
      scaffoldBackgroundColor: background,
    );
    TextStyle? heading(TextStyle? s, {FontWeight weight = FontWeight.w600}) =>
        s?.copyWith(fontFamily: display, fontWeight: weight, color: text);
    final textTheme = base.textTheme.copyWith(
      displayLarge: heading(base.textTheme.displayLarge),
      displayMedium: heading(base.textTheme.displayMedium),
      displaySmall: heading(base.textTheme.displaySmall),
      headlineLarge: heading(base.textTheme.headlineLarge),
      headlineMedium: heading(base.textTheme.headlineMedium),
      headlineSmall: heading(base.textTheme.headlineSmall),
      titleLarge: heading(base.textTheme.titleLarge),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: muted),
      labelSmall: base.textTheme.labelSmall?.copyWith(color: muted),
    );

    const pill = StadiumBorder();
    final rounded16 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: text,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontFamily: display,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: outline, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: text,
          foregroundColor: background,
          disabledBackgroundColor: surfaceHigh,
          disabledForegroundColor: muted,
          shape: pill,
          minimumSize: const Size(64, 50),
          textStyle: const TextStyle(
            fontFamily: body,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: pill,
          minimumSize: const Size(64, 48),
          side: BorderSide(color: outline, width: 1.5),
          foregroundColor: text,
          textStyle: const TextStyle(
            fontFamily: body,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: const TextStyle(
            fontFamily: body,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        hintStyle: TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: primary, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: pill,
        side: BorderSide(color: outline),
        backgroundColor: surface,
        selectedColor: primary.withValues(alpha: isDark ? 0.22 : 0.12),
        checkmarkColor: primary,
        labelStyle: TextStyle(
          fontFamily: body,
          color: text,
          fontWeight: FontWeight.w600,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide(color: outline),
          selectedBackgroundColor: text,
          selectedForegroundColor: background,
          foregroundColor: muted,
          textStyle: const TextStyle(
            fontFamily: body,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: text.withValues(alpha: isDark ? 0.14 : 0.08),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: body,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
            color: states.contains(WidgetState.selected) ? text : muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? text : muted,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: outline,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: TextStyle(
          fontFamily: display,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF1F1F23) : text,
        contentTextStyle: TextStyle(
          fontFamily: body,
          color: isDark ? text : Colors.white,
          fontWeight: FontWeight.w600,
        ),
        shape: rounded16,
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: text),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: outline,
        circularTrackColor: outline,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: text,
        foregroundColor: background,
        elevation: 2,
        shape: pill,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? background : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : surfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        thumbColor: primary,
        inactiveTrackColor: outline,
      ),
    );
  }
}
