import 'package:flutter/material.dart';

import 'screens/catalog_screen.dart';
import 'screens/database_gateway.dart';
import 'screens/search_add_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_controller.dart';
import 'theme/app_theme.dart';

class RpgCatalogBootstrap extends StatefulWidget {
  const RpgCatalogBootstrap({super.key});

  @override
  State<RpgCatalogBootstrap> createState() => _RpgCatalogBootstrapState();
}

class _RpgCatalogBootstrapState extends State<RpgCatalogBootstrap> {
  final AppController _controller = AppController();

  @override
  void initState() {
    super.initState();
    _controller.initialize();
    _controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RPG Catalog',
        debugShowCheckedModeBanner: false,
        theme: buildRpgTheme(_controller.seedName, Brightness.light),
        darkTheme: buildRpgTheme(_controller.seedName, Brightness.dark),
        themeMode: ThemeMode.system,
        home: _controller.loading
            ? const _LoadingScreen()
            : _controller.isOpen
                ? CatalogShell(controller: _controller)
                : DatabaseGateway(
                    controller: _controller, error: _controller.error),
      );
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
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

  String get _title => ['RPG Catalog', 'Add to catalog', 'Settings'][_page];

  @override
  Widget build(BuildContext context) {
    final pages = [
      CatalogScreen(controller: widget.controller),
      SearchAddScreen(
        controller: widget.controller,
        onSaved: () => setState(() => _page = 0),
      ),
      SettingsScreen(controller: widget.controller),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          appBar: AppBar(title: Text(_title)),
          body: Row(
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
