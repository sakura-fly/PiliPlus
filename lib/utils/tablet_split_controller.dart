import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 平板分屏模式下，右侧视频页的参数。
class VideoSplitArguments {
  VideoSplitArguments(List<Map<String, dynamic>> videoStack)
    : videoStack = List.of(videoStack),
      id = _nextId++;

  static int _nextId = 0;

  /// 从栈底到栈顶排列的视频参数，最后一个为当前显示的视频。
  final List<Map<String, dynamic>> videoStack;
  final int id;

  Map<String, dynamic> get arguments => videoStack.last;
}

/// 分屏右侧的一层页面信息，用于横屏切竖屏时保留完整导航栈。
class SplitRouteInfo {
  const SplitRouteInfo({this.name, this.arguments});

  final String? name;
  final Object? arguments;
}

/// 管理平板分屏状态。
///
/// 打开后，[TabletSplitScreenHost] 会把当前 App 压缩到左侧，并在右侧
/// 创建独立的视频页。这样用户可以在不离开当前列表的情况下观看视频。
class TabletSplitController extends ChangeNotifier {
  TabletSplitController._();

  static final TabletSplitController instance = TabletSplitController._();

  VideoSplitArguments? _arguments;
  bool _rightFullScreen = false;
  Map<String, dynamic>? _displayedArguments;
  Map<String, dynamic>? _pendingArguments;
  Size? _screenSize;
  GlobalKey<NavigatorState>? _splitNavigatorKey;
  final List<Route<dynamic>> _rootRoutes = [];
  List<SplitRouteInfo> _rightRouteStack = const [];
  NavigatorState? _rootNavigator;
  Route<dynamic>? _rootTopWhenOpened;
  Object? _fullScreenBackOwner;
  bool Function()? _fullScreenBackHandler;
  bool _replaceRightStackOnNextPush = false;
  bool _lastInteractionFromRight = false;

  // 打开分屏时暂存根路由的 GetX 状态，关闭分屏后恢复。
  String? _rootCurrent;
  String? _rootPrevious;
  dynamic _rootArgs;
  Map<String, String?>? _rootParameters;
  bool _hasSavedRouting = false;

  VideoSplitArguments? get current => _arguments;

  bool get rightFullScreen => _rightFullScreen;

  void setRightFullScreen(bool value) {
    if (_rightFullScreen == value) {
      return;
    }
    _rightFullScreen = value;
    notifyListeners();
  }

  void updateScreenSize(Size size) {
    _screenSize = size;
  }

  void onRootRoutePushed(Route<dynamic> route) {
    _rootRoutes.add(route);
  }

  void onRootRoutePopped(Route<dynamic> route) {
    _rootRoutes.remove(route);
  }

  void onRootRouteRemoved(Route<dynamic> route) {
    _rootRoutes.remove(route);
  }

  void onRootRouteReplaced(
    Route<dynamic>? oldRoute,
    Route<dynamic>? newRoute,
  ) {
    if (oldRoute != null) {
      _rootRoutes.remove(oldRoute);
    }
    if (newRoute != null) {
      _rootRoutes.add(newRoute);
    }
  }

  static String? _routeNameOf(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null) {
      return name;
    }
    return route is GetPageRoute ? route.routeName : null;
  }

  /// 根导航栈中的视频参数，按从栈底到栈顶排列。
  List<Map<String, dynamic>> get rootVideoStack => _rootRoutes
      .where((route) => _routeNameOf(route) == '/videoV')
      .map((route) => route.settings.arguments)
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList(growable: false);

  void _saveRouting() {
    if (_hasSavedRouting) {
      return;
    }
    _rootCurrent = Get.routing.current;
    _rootPrevious = Get.routing.previous;
    _rootArgs = Get.routing.args;
    _rootParameters = Map<String, String?>.from(Get.parameters);
    _hasSavedRouting = true;
  }

  void _restoreRouting() {
    if (!_hasSavedRouting) {
      return;
    }
    Get.routing
      ..current = _rootCurrent ?? ''
      ..previous = _rootPrevious ?? ''
      ..args = _rootArgs;
    Get.parameters = _rootParameters ?? {};
    _hasSavedRouting = false;
  }

  void attachNavigator(GlobalKey<NavigatorState> key) {
    _splitNavigatorKey = key;
  }

  void detachNavigator(GlobalKey<NavigatorState> key) {
    if (identical(_splitNavigatorKey, key)) {
      _splitNavigatorKey = null;
    }
  }

  void registerFullScreenBackHandler(
    Object owner,
    bool Function()? handler,
  ) {
    _fullScreenBackOwner = owner;
    _fullScreenBackHandler = handler;
  }

  void unregisterFullScreenBackHandler(Object owner) {
    if (identical(_fullScreenBackOwner, owner)) {
      _fullScreenBackOwner = null;
      _fullScreenBackHandler = null;
    }
  }

  /// 左侧触发的导航需要清空右侧分屏栈。
  void markInteractionFromLeft() {
    _lastInteractionFromRight = false;
    if (isOpen) {
      _replaceRightStackOnNextPush = true;
    }
  }

  /// 右侧触发的导航保留右侧分屏栈，向上堆叠。
  void markInteractionFromRight() {
    _lastInteractionFromRight = true;
    _replaceRightStackOnNextPush = false;
  }

  bool get isInteractionFromRight => _lastInteractionFromRight;

  bool consumeReplaceRightStack() {
    final replace = _replaceRightStackOnNextPush;
    _replaceRightStackOnNextPush = false;
    return replace;
  }

  void updateRightRouteStack(List<SplitRouteInfo> stack) {
    _rightRouteStack = stack;
  }

  /// 优先处理全屏、右侧分屏、右侧 Navigator 和根导航中新压入的页面，
  /// 最后才关闭分屏，避免直接退出。
  void handleBack() {
    if (_rightFullScreen) {
      final handler = _fullScreenBackHandler;
      if (handler != null && handler()) {
        return;
      }
    }

    final navigator = _splitNavigatorKey?.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }

    final current = _arguments;
    if (navigator != null && current != null && current.videoStack.length > 1) {
      current.videoStack.removeLast();
      final previous = current.videoStack.last;
      _displayedArguments = previous;
      setRightFullScreen(false);
      navigator.pushReplacementNamed('/videoV', arguments: previous);
      return;
    }

    // 有些右侧页面在 GetX 路由状态切换时可能被压到根导航上，
    // 这里一并按层返回，直到回到打开分屏时的根页面。
    final rootNavigator = _rootNavigator;
    final rootTop = _rootRoutes.isNotEmpty ? _rootRoutes.last : null;
    if (rootNavigator != null &&
        rootNavigator.canPop() &&
        rootTop != null &&
        rootTop != _rootTopWhenOpened) {
      rootNavigator.pop();
      return;
    }

    close();
  }

  bool get isOpen => _arguments != null;

  bool get _canSplit {
    if (!Pref.tabletSplitScreen) {
      return false;
    }
    try {
      if (!DeviceUtils.isTablet) {
        return false;
      }
      final screenSize = _screenSize;
      if (screenSize != null) {
        return screenSize.width >= 600 && screenSize.width > screenSize.height;
      }
      final size = DeviceUtils.size;
      return size.width >= 600 && size.width > size.height;
    } catch (_) {
      return false;
    }
  }

  /// 尝试在右侧打开视频。返回 false 表示当前环境不应使用分屏。
  ///
  /// [videoStack] 用于把竖屏时根导航栈里的多个视频整体迁入右侧。
  bool open(
    Map<String, dynamic> arguments, {
    List<Map<String, dynamic>>? videoStack,
  }) {
    if (!_canSplit) {
      return false;
    }
    final current = _arguments;
    if (current != null) {
      final displayed = _displayedArguments ?? current.arguments;
      if (displayed['heroTag'] == arguments['heroTag']) {
        return true;
      }

      final navigator = _splitNavigatorKey?.currentState;
      if (navigator != null) {
        // 左侧再次点视频时直接“顶掉”右侧内容：
        // 清空右侧导航栈和虚拟视频栈，只保留最新视频。
        setRightFullScreen(false);
        current.videoStack
          ..clear()
          ..add(arguments);
        _displayedArguments = arguments;
        navigator.pushNamedAndRemoveUntil(
          '/videoV',
          (route) => false,
          arguments: arguments,
        );
        return true;
      }

      // 分屏外壳尚未挂载完成时，退回“下一帧重建右侧”的旧逻辑。
      setRightFullScreen(false);
      _pendingArguments = arguments;
      _arguments = null;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pendingArguments = _pendingArguments;
        if (pendingArguments == null || !Pref.tabletSplitScreen) {
          return;
        }
        _pendingArguments = null;
        _displayedArguments = pendingArguments;
        _arguments = VideoSplitArguments([pendingArguments]);
        notifyListeners();
      });
      return true;
    }

    _saveRouting();
    _rootNavigator = Get.key.currentState;
    _rootTopWhenOpened = _rootRoutes.isNotEmpty ? _rootRoutes.last : null;
    _pendingArguments = null;
    _rightFullScreen = false;
    _displayedArguments = arguments;
    _arguments = VideoSplitArguments(videoStack ?? [arguments]);
    notifyListeners();
    return true;
  }

  /// 从右侧打开视频：在当前右侧视频栈上继续向上堆叠。
  bool openFromRight(Map<String, dynamic> arguments) {
    if (!_canSplit) {
      return false;
    }
    final current = _arguments;
    if (current == null) {
      return open(arguments);
    }
    final displayed = _displayedArguments ?? current.arguments;
    if (displayed['heroTag'] == arguments['heroTag']) {
      return true;
    }
    final navigator = _splitNavigatorKey?.currentState;
    setRightFullScreen(false);
    current.videoStack.add(arguments);
    _displayedArguments = arguments;
    if (navigator != null) {
      navigator.pushNamed('/videoV', arguments: arguments);
      return true;
    }
    return open(arguments, videoStack: List.of(current.videoStack));
  }

  /// 横屏分屏切回竖屏时：关闭分屏，并把右侧完整导航栈重新压入根导航栈。
  void collapseToPortrait() {
    final current = _arguments;
    if (current == null || current.videoStack.isEmpty) {
      return;
    }
    final routeStack = List<SplitRouteInfo>.from(_rightRouteStack);
    final videoStack = List<Map<String, dynamic>>.from(current.videoStack);
    close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (routeStack.isNotEmpty) {
        for (final route in routeStack) {
          final name = route.name;
          if (name == null || name.isEmpty) {
            continue;
          }
          Get.toNamed(
            name,
            arguments: route.arguments,
            preventDuplicates: false,
          );
        }
        return;
      }
      for (final args in videoStack) {
        Get.toNamed(
          '/videoV',
          arguments: args,
          preventDuplicates: false,
        );
      }
    });
  }

  /// 竖屏切回横屏时：把根导航栈里的视频迁入右侧分屏，左侧保留根页面。
  void convertRootVideosToSplit(List<Map<String, dynamic>> videoStack) {
    if (videoStack.isEmpty || _arguments != null) {
      return;
    }
    // 根导航栈里至少要有一个非视频页面，否则左侧没有可保留的页面。
    if (!_rootRoutes.any((route) => _routeNameOf(route) != '/videoV')) {
      return;
    }
    final rootNavigator = Get.key.currentState;
    if (rootNavigator == null) {
      return;
    }
    rootNavigator.popUntil((route) => route.isFirst);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_arguments != null) {
        return;
      }
      open(videoStack.last, videoStack: videoStack);
    });
  }

  void close() {
    _pendingArguments = null;
    _rightFullScreen = false;
    _displayedArguments = null;
    _rightRouteStack = const [];
    _rootNavigator = null;
    _rootTopWhenOpened = null;
    _fullScreenBackOwner = null;
    _fullScreenBackHandler = null;
    _replaceRightStackOnNextPush = false;
    _lastInteractionFromRight = false;
    if (_arguments == null) {
      _restoreRouting();
      return;
    }
    _arguments = null;
    _restoreRouting();
    notifyListeners();
  }
}

/// 记录根导航栈的页面，用于竖屏视频栈迁移到分屏。
class TabletSplitRootObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    TabletSplitController.instance.onRootRoutePushed(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    TabletSplitController.instance.onRootRoutePopped(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    TabletSplitController.instance.onRootRouteRemoved(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    TabletSplitController.instance.onRootRouteReplaced(oldRoute, newRoute);
  }
}

final tabletSplitRootObserver = TabletSplitRootObserver();
