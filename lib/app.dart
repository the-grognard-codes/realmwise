import 'dart:async';

import 'package:flutter/material.dart';
import 'debug/api_debug_harness.dart';
import 'screens/catalog_screen.dart';
import 'screens/database_gateway.dart';
import 'screens/search_add_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_controller.dart';
import 'services/google_drive_runtime.dart';
import 'services/onedrive_runtime.dart';
import 'services/dropbox_runtime.dart';
import 'theme/app_theme.dart';

class RealmwiseBootstrap extends StatefulWidget {
  const RealmwiseBootstrap({super.key});

  @override
  State<RealmwiseBootstrap> createState() => _RealmwiseBootstrapState();
}

class _RealmwiseBootstrapState extends State<RealmwiseBootstrap> {
  AppController? _controller;
  ApiDebugHarness? _debugHarness;
  Future<ApiDebugHarness>? _debugStart;
  bool _disposed = false;
  bool _cleanupStarted = false;
  Object? _bootstrapError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final androidConfiguration = await loadAndroidOAuthConfiguration();
      if (_disposed) return;
      final controller = AppController(
        googleDriveProvider: createConfiguredGoogleDriveProvider(
          androidConfiguration,
        ),
        oneDriveProvider: createConfiguredOneDriveProvider(
          androidConfiguration,
        ),
        dropboxProvider: createConfiguredDropboxProvider(androidConfiguration),
      );
      _controller = controller;
      if (mounted) setState(() {});
      logGoogleDriveConfiguration();
      logOneDriveConfiguration();
      logDropboxConfiguration();
      final readiness = controller.initialize();
      if (apiDebugHarnessEnabled()) {
        _debugStart = ApiDebugHarness.start(controller, readiness: readiness);
        unawaited(
          _debugStart!.then<void>(
            (harness) {
              if (!_disposed) _debugHarness = harness;
            },
            onError: (Object error, StackTrace stack) {
              debugPrint('API debug harness failed to start: $error');
            },
          ),
        );
      }
      controller.addListener(_refresh);
    } catch (error) {
      if (_disposed) return;
      _bootstrapError = error;
      if (mounted) setState(() {});
    }
  }

  void _retryBootstrap() {
    setState(() => _bootstrapError = null);
    unawaited(_bootstrap());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _controller;
    controller?.removeListener(_refresh);
    if (controller == null) {
      super.dispose();
      return;
    }
    if (_cleanupStarted) {
      super.dispose();
      return;
    }
    _cleanupStarted = true;
    final harness = _debugHarness;
    _debugHarness = null;
    if (harness != null) {
      harness.close().whenComplete(controller.dispose);
    } else if (_debugStart == null) {
      controller.dispose();
    } else {
      unawaited(
        _debugStart!.then(
          (started) async {
            try {
              await started.close();
            } catch (_) {}
            controller.dispose();
          },
          onError: (_) {
            controller.dispose();
          },
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      final error = _bootstrapError;
      if (error != null) {
        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Unable to initialize cloud configuration.'),
                    const SizedBox(height: 8),
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _retryBootstrap,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return const MaterialApp(home: _LoadingScreen());
    }
    return MaterialApp(
      title: 'Realmwise RPG Tracker',
      debugShowCheckedModeBanner: false,
      theme: buildRpgTheme(controller.seedName, Brightness.light),
      darkTheme: buildRpgTheme(controller.seedName, Brightness.dark),
      themeMode: controller.themeMode,
      home: controller.loading
          ? const _LoadingScreen()
          : controller.isOpen && controller.error == null
          ? CatalogShell(controller: controller)
          : DatabaseGateway(controller: controller, error: controller.error),
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final imageWidth = (constraints.maxWidth * 0.8)
              .clamp(1.0, 520.0)
              .toDouble();
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/branding/publication/realmwise-splash.png',
                      width: imageWidth,
                      fit: BoxFit.contain,
                      semanticLabel: 'Realmwise',
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Preparing your catalog…',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Semantics(
                      label: 'Loading catalog',
                      child: CircularProgressIndicator(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class CatalogShell extends StatefulWidget {
  const CatalogShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<CatalogShell> createState() => _CatalogShellState();
}

class _CatalogShellState extends State<CatalogShell> {
  int _page = 0;
  final _destinations = const [
    NavigationDestination(
      icon: Icon(Icons.auto_stories_outlined),
      selectedIcon: Icon(Icons.auto_stories),
      label: 'Catalog',
    ),
    NavigationDestination(
      icon: Icon(Icons.add_circle_outline),
      selectedIcon: Icon(Icons.add_circle),
      label: 'Add book',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      CatalogScreen(controller: widget.controller),
      SearchAddScreen(
        controller: widget.controller,
        onSaved: () => setState(() => _page = 0),
        onBack: () => setState(() => _page = 0),
      ),
      SettingsScreen(
        controller: widget.controller,
        onSyncRestore: () => setState(() => _page = 0),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          body: SafeArea(
            top: true,
            bottom: false,
            child: Row(
              children: [
                if (wide)
                  NavigationRail(
                    selectedIndex: _page,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (index) =>
                        setState(() => _page = index),
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Icon(
                        Icons.shield,
                        color: Theme.of(context).colorScheme.primary,
                        size: 32,
                      ),
                    ),
                    destinations: _destinations
                        .map(
                          (item) => NavigationRailDestination(
                            icon: item.icon,
                            selectedIcon: item.selectedIcon,
                            label: Text(item.label),
                          ),
                        )
                        .toList(),
                  ),
                Expanded(child: pages[_page]),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _page,
                  onDestinationSelected: (index) =>
                      setState(() => _page = index),
                  destinations: _destinations,
                ),
        );
      },
    );
  }
}
