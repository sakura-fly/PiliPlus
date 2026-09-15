import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/utils/tablet_split_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 平板分屏的外壳：分屏开启时左侧保留整个 App，右侧显示视频页。
class TabletSplitScreenHost extends StatefulWidget {
  const TabletSplitScreenHost({super.key, required this.child});

  final Widget child;

  @override
  State<TabletSplitScreenHost> createState() => _TabletSplitScreenHostState();
}

class _TabletSplitScreenHostState extends State<TabletSplitScreenHost> {
  final _controller = TabletSplitController.instance;
  late final GlobalKey<NavigatorState> _rootNavigatorKey = Get.key;
  Orientation? _lastOrientation;
  bool _orientationTransitionScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSplitChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onSplitChanged);
    _restoreRootNavigatorKey();
    super.dispose();
  }

  void _onSplitChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _restoreRootNavigatorKey() {
    if (Get.key != _rootNavigatorKey) {
      Get.addKey(_rootNavigatorKey);
    }
  }

  void _handleOrientationTransition(Orientation from, Orientation to) {
    if (from == Orientation.landscape && to == Orientation.portrait) {
      if (_controller.isOpen) {
        _controller.collapseToPortrait();
      }
      return;
    }
    if (from == Orientation.portrait && to == Orientation.landscape) {
      if (_controller.isOpen || Get.currentRoute != '/videoV') {
        return;
      }
      final videoStack = List<Map<String, dynamic>>.from(
        _controller.rootVideoStack,
      );
      if (videoStack.isNotEmpty) {
        _controller.convertRootVideosToSplit(videoStack);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    _controller.updateScreenSize(screenSize);

    final orientation = screenSize.width > screenSize.height
        ? Orientation.landscape
        : Orientation.portrait;
    final lastOrientation = _lastOrientation;
    _lastOrientation = orientation;
    if (lastOrientation != null &&
        lastOrientation != orientation &&
        !_orientationTransitionScheduled) {
      _orientationTransitionScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _orientationTransitionScheduled = false;
        if (!mounted) {
          return;
        }
        _handleOrientationTransition(lastOrientation, orientation);
      });
    }

    final splitArguments = _controller.current;
    if (splitArguments == null) {
      _restoreRootNavigatorKey();
      return widget.child;
    }
    final isRightFullScreen = _controller.rightFullScreen;

    // 左右 50/50；左侧用小于 600dp 的逻辑宽度，保证手机竖屏布局。
    var leftWidth = screenSize.width * 0.5;
    if (leftWidth < 280) {
      leftWidth = 280;
    }
    if (leftWidth > screenSize.width - 320) {
      leftWidth = screenSize.width - 320;
    }
    if (leftWidth < 0) {
      leftWidth = 0;
    }
    final leftLogicalWidth = leftWidth > 599 ? 599.0 : leftWidth;
    final rightWidth = isRightFullScreen
        ? screenSize.width
        : screenSize.width - leftWidth;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: leftWidth,
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: Size(leftLogicalWidth, screenSize.height),
            ),
            child: widget.child,
          ),
        ),
        Positioned(
          left: isRightFullScreen ? 0 : leftWidth,
          top: 0,
          bottom: 0,
          width: rightWidth,
          child: _VideoSplitPane(
            key: ValueKey(splitArguments.id),
            splitArguments: splitArguments,
            width: rightWidth,
            height: screenSize.height,
          ),
        ),
      ],
    );
  }
}

class _VideoSplitPane extends StatefulWidget {
  const _VideoSplitPane({
    super.key,
    required this.splitArguments,
    required this.width,
    required this.height,
  });

  final VideoSplitArguments splitArguments;
  final double width;
  final double height;

  @override
  State<_VideoSplitPane> createState() => _VideoSplitPaneState();
}

class _VideoSplitPaneState extends State<_VideoSplitPane> {
  late final _navigatorKey = GlobalKey<NavigatorState>();
  late final _observer = _SplitNavigatorObserver(splitKey: _navigatorKey);

  @override
  void initState() {
    super.initState();
    TabletSplitController.instance.attachNavigator(_navigatorKey);
  }

  @override
  void dispose() {
    _observer.enabled = false;
    TabletSplitController.instance.detachNavigator(_navigatorKey);
    super.dispose();
  }

  Route<dynamic> _buildVideoRoute(Map<String, dynamic> arguments) {
    return MaterialPageRoute<void>(
      settings: RouteSettings(
        name: '/videoV',
        arguments: arguments,
      ),
      builder: (context) => VideoDetailPageV(
        arguments: arguments,
        isSplitScreen: true,
        forcePortrait: true,
      ),
    );
  }

  Route<dynamic> _onGenerateRoute(RouteSettings settings) {
    final routeName = settings.name;
    if (routeName == null ||
        routeName == Navigator.defaultRouteName ||
        routeName == '/videoV') {
      final rawArguments = settings.arguments;
      final arguments = rawArguments is Map
          ? Map<String, dynamic>.from(rawArguments)
          : widget.splitArguments.arguments;
      return _buildVideoRoute(arguments);
    }

    // 分屏内的 Navigator 也要能解析全局命名路由，
    // 否则点击“设置”等入口时会一直停留在视频页。
    final match = Get.routeTree.matchRoute(
      routeName,
      arguments: settings.arguments,
    );
    final page = match.route;
    if (page == null) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => const SizedBox.shrink(),
      );
    }
    Get.parameters = match.parameters;
    return GetPageRoute<void>(
      page: page.page,
      parameter: page.parameters,
      settings: settings,
      binding: page.binding,
      bindings: page.bindings,
      middlewares: page.middlewares,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            left: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
        ),
        child: ClipRect(
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: Size(widget.width, widget.height),
            ),
            child: Navigator(
              key: _navigatorKey,
              observers: [_observer],
              onGenerateRoute: _onGenerateRoute,
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitNavigatorObserver extends NavigatorObserver {
  _SplitNavigatorObserver({required this.splitKey});

  final GlobalKey<NavigatorState> splitKey;
  final List<Route<dynamic>> _history = [];
  bool enabled = true;

  static String _routeName(Route<dynamic>? route) => route?.settings.name ?? '';

  void _syncNavigatorKey() {
    if (Get.key != splitKey) {
      Get.addKey(splitKey);
    }
  }

  /// 分屏里的页面同样可能使用 Get.arguments / Get.parameters，
  /// 这里同步 GetX 的路由状态，但保留 Get.routing.route 指向根路由，
  /// 以便根路由的 PopScope 仍能拦截系统返回。
  void _syncRouting() {
    final route = _history.isNotEmpty ? _history.last : null;
    final previousRoute = _history.length > 1
        ? _history[_history.length - 2]
        : null;
    Get.routing
      ..current = _routeName(route)
      ..previous = _routeName(previousRoute)
      ..args = route?.settings.arguments;
    Get.parameters = route is GetPageRoute
        ? Map<String, String?>.from(route.parameter ?? const {})
        : {};
  }

  void _sync() {
    if (!enabled) {
      return;
    }
    _syncNavigatorKey();
    _syncRouting();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _history.add(route);
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _history.remove(route);
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _history.remove(route);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) {
      _history.remove(oldRoute);
    }
    if (newRoute != null) {
      _history.add(newRoute);
    }
    _sync();
  }
}
