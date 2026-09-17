import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
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
  ScrollableState? _blankScrollable;

  @override
  void initState() {
    super.initState();
    _controller
      ..attachRootNavigatorKey(_rootNavigatorKey)
      ..addListener(_onSplitChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onSplitChanged)
      ..detachRootNavigatorKey(_rootNavigatorKey);
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

  ScrollableState? _findVerticalScrollable() {
    ScrollableState? result;
    void visitor(Element element) {
      if (result != null) {
        return;
      }
      final state = element is StatefulElement ? element.state : null;
      if (state is ScrollableState) {
        final position = state.position;
        if (position.axis == Axis.vertical &&
            position.maxScrollExtent > position.minScrollExtent) {
          result = state;
          return;
        }
      }
      element.visitChildren(visitor);
    }

    (context as Element).visitChildren(visitor);
    return result;
  }

  void _onBlankDragStart(DragStartDetails details) {
    _blankScrollable = _findVerticalScrollable();
  }

  void _onBlankDragUpdate(DragUpdateDetails details) {
    final state = _blankScrollable;
    if (state == null || !state.mounted) {
      _blankScrollable = null;
      return;
    }
    final position = state.position;
    final target = (position.pixels - details.delta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(target.toDouble());
  }

  void _onBlankDragEnd(DragEndDetails details) {
    final state = _blankScrollable;
    _blankScrollable = null;
    if (state == null || !state.mounted) {
      return;
    }
    final position = state.position;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 50) {
      return;
    }
    final target = (position.pixels - velocity * 0.22).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final duration = (velocity.abs() / 5).clamp(180, 650).round();
    position.animateTo(
      target.toDouble(),
      duration: Duration(milliseconds: duration),
      curve: Curves.decelerate,
    );
  }

  Widget _buildStandalonePortrait(
    MediaQueryData mediaQuery,
    Size screenSize,
  ) {
    final width = screenSize.width * 0.5;
    final sideWidth = (screenSize.width - width) / 2;

    Widget side() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _onBlankDragStart,
      onVerticalDragUpdate: _onBlankDragUpdate,
      onVerticalDragEnd: _onBlankDragEnd,
      onVerticalDragCancel: () => _blankScrollable = null,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (sideWidth > 0)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: sideWidth,
            child: side(),
          ),
        if (sideWidth > 0)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: sideWidth,
            child: side(),
          ),
        Center(
          child: SizedBox(
            width: width,
            height: screenSize.height,
            child: MediaQuery(
              data: mediaQuery.copyWith(
                size: Size(width, screenSize.height),
              ),
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    _controller.updateScreenSize(screenSize);

    final splitArguments = _controller.current;
    final leftArguments = _controller.leftCurrent;
    final standalonePortrait =
        splitArguments == null &&
        leftArguments == null &&
        Pref.tabletSplitScreen &&
        // 与 TabletSplitController._canSplit 的平板判断保持一致，
        // 避免手机横屏时也进入半屏模式却无法分屏。
        screenSize.shortestSide >= 600 &&
        screenSize.width > screenSize.height;
    _controller.setStandalonePortrait(standalonePortrait);
    if (splitArguments == null && leftArguments == null) {
      _restoreRootNavigatorKey();
      if (standalonePortrait) {
        if (_controller.isLeftStandaloneFullScreen) {
          return widget.child;
        }
        return _buildStandalonePortrait(mediaQuery, screenSize);
      }
      return widget.child;
    }
    final isRightFullScreen = _controller.rightFullScreen;
    final isPortrait = screenSize.width <= screenSize.height;
    final leftOnRight = _controller.isLeftPaneOnRight;
    final leftFull = _controller.isLeftPaneFullScreen;
    debugPrint(
      '[PiliSplit] host build right=${splitArguments?.id} '
      'left=${leftArguments?.id} onRight=$leftOnRight full=$leftFull',
    );

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
    final rightFull = isRightFullScreen || isPortrait;
    final rightWidth = rightFull
        ? screenSize.width
        : screenSize.width - leftWidth;
    final leftLogicalWidth = leftWidth > 599 ? 599.0 : leftWidth;

    Widget rootApp() => Listener(
      // 左侧主界面同样要上报表交互来源，否则：
      // 1. 之后点击左侧视频会被当成右侧来源压到右侧栈上；
      // 2. 返回键会优先处理右侧；
      // 3. _replaceRightStackOnNextPush 不会置位，右侧旧栈无法清空。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _controller.markInteractionFromLeft(),
      child: MediaQuery(
        data: mediaQuery.copyWith(
          size: Size(leftLogicalWidth, screenSize.height),
        ),
        child: widget.child,
      ),
    );

    Widget pane(
      VideoSplitArguments arguments, {
      required bool isLeft,
    }) => Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (isLeft) {
          _controller
            ..markInteractionFromLeft()
            ..useLeftNavigatorKey();
        } else {
          _controller
            ..markInteractionFromRight()
            ..useSplitNavigatorKey();
        }
      },
      child: _VideoSplitPane(
        key: ValueKey('${isLeft ? 'left' : 'right'}-${arguments.id}'),
        splitArguments: arguments,
        width: isLeft
            ? leftOnRight
                  ? rightWidth
                  : leftWidth
            : rightFull
            ? screenSize.width
            : rightWidth,
        height: screenSize.height,
        isLeft: isLeft,
      ),
    );

    // pane 用稳定 key：左 pane 出现/消失时，Stack 不会按 index 把右 pane
    // 误当成新 widget 重建（否则右 pane 的 Navigator/播放状态会被重置）。
    Widget leftPane() => Positioned(
      key: ValueKey('split-left-${leftArguments!.id}'),
      left: leftFull
          ? 0
          : leftOnRight
          ? leftWidth
          : 0,
      top: 0,
      bottom: 0,
      width: leftFull
          ? screenSize.width
          : leftOnRight
          ? rightWidth
          : leftWidth,
      child: pane(leftArguments, isLeft: true),
    );

    Widget rightPane() => Positioned(
      key: ValueKey('split-right-${splitArguments!.id}'),
      left: rightFull ? 0 : leftWidth,
      top: 0,
      bottom: 0,
      width: rightWidth,
      child: pane(splitArguments, isLeft: false),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: leftWidth,
          child: rootApp(),
        ),
        if (leftArguments != null) leftPane(),
        if (splitArguments != null && !leftOnRight && !leftFull) rightPane(),
        if (leftArguments != null &&
            splitArguments == null &&
            !leftOnRight &&
            !leftFull)
          Positioned(
            left: leftWidth,
            top: 0,
            bottom: 0,
            width: rightWidth,
            child: ColoredBox(color: ColorScheme.of(context).surface),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: mediaQuery.padding.top + 6,
          child: Center(
            child: Material(
              color: ColorScheme.of(context).surface.withValues(alpha: 0.86),
              elevation: 2,
              shape: const CircleBorder(),
              child: IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _controller.isLocked ? '取消锁定' : '锁定分屏',
                onPressed: () {
                  _controller.toggleLock();
                  if (_controller.isLocked) {
                    _restoreRootNavigatorKey();
                  } else {
                    _controller.useSplitNavigatorKey();
                  }
                },
                icon: Icon(
                  _controller.isLocked ? Icons.lock : Icons.lock_open,
                  size: 18,
                ),
              ),
            ),
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
    this.isLeft = false,
  });

  final VideoSplitArguments splitArguments;
  final double width;
  final double height;
  final bool isLeft;

  @override
  State<_VideoSplitPane> createState() => _VideoSplitPaneState();
}

class _VideoSplitPaneState extends State<_VideoSplitPane> {
  late final _navigatorKey = GlobalKey<NavigatorState>();
  late final _observer = _SplitNavigatorObserver(
    splitKey: _navigatorKey,
    isLeft: widget.isLeft,
  );
  // pane 内部独立的 RouteObserver，直接传给视频页订阅：
  // 返回上一层时触发 didPopNext，让下层视频重新加载自己的播放源。
  final _paneRouteObserver = RouteObserver<ModalRoute<dynamic>>();

  @override
  void initState() {
    super.initState();
    if (widget.isLeft) {
      TabletSplitController.instance.attachLeftNavigator(_navigatorKey);
    } else {
      TabletSplitController.instance.attachNavigator(_navigatorKey);
    }
  }

  @override
  void dispose() {
    _observer.enabled = false;
    if (widget.isLeft) {
      TabletSplitController.instance.detachLeftNavigator(_navigatorKey);
    } else {
      TabletSplitController.instance.detachNavigator(_navigatorKey);
    }
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
        leftPane: widget.isLeft,
        paneRouteObserver: _paneRouteObserver,
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
      debugPrint(
        '[PiliSplit] genRoute ${widget.isLeft ? 'L' : 'R'} '
        'name=$routeName cid=${arguments['cid']} '
        'raw=${rawArguments is Map ? 'map' : 'fallback'}',
      );
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
              observers: [_observer, _paneRouteObserver],
              onGenerateRoute: _onGenerateRoute,
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitNavigatorObserver extends NavigatorObserver {
  _SplitNavigatorObserver({required this.splitKey, this.isLeft = false});

  final GlobalKey<NavigatorState> splitKey;
  final bool isLeft;
  final List<Route<dynamic>> _history = [];
  bool enabled = true;

  static String _routeName(Route<dynamic>? route) => route?.settings.name ?? '';

  String _cid(Route<dynamic>? route) {
    final args = route?.settings.arguments;
    return args is Map ? '${args['cid']}' : '-';
  }

  void _logRoute(String event, Route<dynamic>? route) {
    debugPrint(
      '[PiliSplit] ${isLeft ? 'L' : 'R'} $event '
      'name=${_routeName(route)} cid=${_cid(route)} '
      'history=${_history.length}',
    );
  }

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
    final routeStack = <SplitRouteInfo>[];
    for (final route in _history) {
      if (route is! PageRoute) {
        continue;
      }
      final name = _routeName(route);
      routeStack.add(
        SplitRouteInfo(
          name: name.isEmpty ? null : name,
          arguments: route.settings.arguments,
        ),
      );
    }
    if (isLeft) {
      TabletSplitController.instance.updateLeftRouteStack(routeStack);
    } else {
      TabletSplitController.instance.updateRightRouteStack(routeStack);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _history.add(route);
    _logRoute('didPush', route);

    // 左侧入口打开的新页面：把右侧已有点击栈整体清掉，
    // 让新页面成为分屏里的最底层。
    if (!isLeft &&
        route is PageRoute &&
        TabletSplitController.instance.consumeReplaceRightStack()) {
      final navigator = this.navigator;
      if (navigator != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!navigator.mounted) {
            return;
          }
          try {
            while (!route.isFirst) {
              navigator.removeRouteBelow(route);
            }
          } catch (_) {
            // 某些平台/Flutter 版本不支持 removeRouteBelow 时忽略，
            // 后续返回逻辑仍会逐层处理。
          }
        });
      }
    }

    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _logRoute('didPop', route);
    _history.remove(route);
    if (route is PageRoute && _routeName(route) == '/videoV') {
      if (isLeft) {
        TabletSplitController.instance.onLeftVideoPopped();
      } else {
        TabletSplitController.instance.onRightVideoPopped();
      }
    }
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _logRoute('didRemove', route);
    _history.remove(route);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _logRoute('didReplace new', newRoute);
    _logRoute('didReplace old', oldRoute);
    if (oldRoute != null) {
      _history.remove(oldRoute);
    }
    if (newRoute != null) {
      _history.add(newRoute);
    }
    _sync();
  }
}
