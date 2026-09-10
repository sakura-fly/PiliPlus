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

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    _controller.updateScreenSize(screenSize);

    final splitArguments = _controller.current;
    if (splitArguments == null) {
      _restoreRootNavigatorKey();
      return widget.child;
    }
    var rightWidth = screenSize.width * 0.42;
    if (rightWidth < 320) {
      rightWidth = 320;
    } else if (rightWidth > 560) {
      rightWidth = 560;
    }
    if (rightWidth > screenSize.width * 0.6) {
      rightWidth = screenSize.width * 0.6;
    }
    final leftWidth = screenSize.width - rightWidth;

    return Row(
      children: [
        SizedBox(
          width: leftWidth,
          height: screenSize.height,
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: Size(leftWidth, screenSize.height),
            ),
            child: widget.child,
          ),
        ),
        _VideoSplitPane(
          key: ValueKey(splitArguments.id),
          rootNavigatorKey: _rootNavigatorKey,
          splitArguments: splitArguments,
          width: rightWidth,
          height: screenSize.height,
        ),
      ],
    );
  }
}

class _VideoSplitPane extends StatefulWidget {
  const _VideoSplitPane({
    super.key,
    required this.rootNavigatorKey,
    required this.splitArguments,
    required this.width,
    required this.height,
  });

  final GlobalKey<NavigatorState> rootNavigatorKey;
  final VideoSplitArguments splitArguments;
  final double width;
  final double height;

  @override
  State<_VideoSplitPane> createState() => _VideoSplitPaneState();
}

class _VideoSplitPaneState extends State<_VideoSplitPane> {
  late final _navigatorKey = GlobalKey<NavigatorState>();
  late final _observer = _SplitNavigatorObserver(
    splitKey: _navigatorKey,
    rootKey: widget.rootNavigatorKey,
  );

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
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: const RouteSettings(name: '/videoV'),
                builder: (context) => VideoDetailPageV(
                  arguments: widget.splitArguments.arguments,
                  isSplitScreen: true,
                  forcePortrait: true,
                  onClose: TabletSplitController.instance.close,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitNavigatorObserver extends NavigatorObserver {
  _SplitNavigatorObserver({required this.splitKey, required this.rootKey});

  final GlobalKey<NavigatorState> splitKey;
  final GlobalKey<NavigatorState> rootKey;

  void _syncNavigatorKey() {
    final navigator = this.navigator;
    if (navigator == null) {
      return;
    }
    if (navigator.canPop()) {
      if (Get.key != splitKey) {
        Get.addKey(splitKey);
      }
    } else if (Get.key != rootKey) {
      Get.addKey(rootKey);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _syncNavigatorKey();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _syncNavigatorKey();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _syncNavigatorKey();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _syncNavigatorKey();
  }
}
