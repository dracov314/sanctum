import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router.dart';

void main() {
  runApp(const ProviderScope(child: SanctumApp()));
}

class SanctumApp extends ConsumerWidget {
  const SanctumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Sanctum',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      routerConfig: router,
    );
  }

  ThemeData _buildTheme() {
    const seed = Color(0xFF8C2F2F); // oxblood red — "dim tavern" palette
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xFF241A12),
      ),
      scaffoldBackgroundColor: const Color(0xFF19130E),
      cardTheme: const CardThemeData(
        color: Color(0xFF2C2016),
        elevation: 0,
      ),
    );
    // Headings in serif ('Spectral', Georgia fallback) per the design handoff.
    const serif = ['Spectral', 'Georgia', 'serif'];
    final t = base.textTheme;
    return base.copyWith(
      textTheme: t.copyWith(
        displayLarge:   t.displayLarge?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        displayMedium:  t.displayMedium?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        displaySmall:   t.displaySmall?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        headlineLarge:  t.headlineLarge?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        headlineMedium: t.headlineMedium?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        headlineSmall:  t.headlineSmall?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
        titleLarge:     t.titleLarge?.copyWith(fontFamily: 'Georgia', fontFamilyFallback: serif),
      ),
    );
  }
}
