import 'dart:async';

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

  void _log(String message) {
    debugPrint('[PiliSplit] $message');
  }

  VideoSplitArguments? _arguments;
  bool _rightFullScreen = false;
  Map<String, dynamic>? _displayedArguments;
  Map<String, dynamic>? _pendingArguments;
  Size? _screenSize;
  GlobalKey<NavigatorState>? _splitNavigatorKey;
  GlobalKey<NavigatorState>? _rootNavigatorKey;
  final List<Route<dynamic>> _rootRoutes = [];
  List<SplitRouteInfo> _rightRouteStack = const [];
  List<SplitRouteInfo> _leftRouteStack = const [];

  List<SplitRouteInfo> get leftRouteStack => _leftRouteStack;
  NavigatorState? _rootNavigator;
  Route<dynamic>? _rootTopWhenOpened;
  Object? _fullScreenBackOwner;
  bool Function()? _fullScreenBackHandler;
  bool _replaceRightStackOnNextPush = false;
  bool _lastInteractionFromRight = false;
  bool _handlingBack = false;
  bool _locked = false;
  bool _standalonePortrait = false;
  bool _leftStandaloneFullScreen = false;
  bool _leftInlineVideo = false;
  bool _paneOnLeft = false;
  VideoSplitArguments? _leftArguments;
  bool _leftPaneOnRight = false;
  bool _leftPaneFullScreen = false;
  GlobalKey<NavigatorState>? _leftSplitNavigatorKey;

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

  /// 如果右侧视频正处于全屏，先退出全屏。
  ///
  /// 左侧在锁定状态下打开新视频时，两个视频页共用同一个播放器实例，
  /// 右侧残留的全屏状态会让左侧新视频页只显示播放器、隐藏下方内容。
  bool exitRightFullScreen() {
    final handler = _fullScreenBackHandler;
    if (handler != null && handler()) {
      return true;
    }
    if (_rightFullScreen) {
      setRightFullScreen(false);
    }
    return false;
  }

  VideoSplitArguments? get leftCurrent => _leftArguments;

  bool get isLeftPaneOnRight => _leftPaneOnRight;

  bool get isLeftPaneFullScreen => _leftPaneFullScreen;

  void setLeftPaneFullScreen(bool value) {
    if (_leftPaneFullScreen == value) {
      return;
    }
    _leftPaneFullScreen = value;
    notifyListeners();
  }

  bool get hasLeftPane => _leftArguments != null;

  void attachLeftNavigator(GlobalKey<NavigatorState> key) {
    _leftSplitNavigatorKey = key;
  }

  void detachLeftNavigator(GlobalKey<NavigatorState> key) {
    if (identical(_leftSplitNavigatorKey, key)) {
      _leftSplitNavigatorKey = null;
    }
  }

  void useLeftNavigatorKey() {
    final key = _leftSplitNavigatorKey;
    if (key != null && Get.key != key) {
      Get.addKey(key);
    }
  }

  bool openLeft(Map<String, dynamic> arguments) {
    _log(
      'openLeft start leftPaneOnRight=$_leftPaneOnRight left=${_leftArguments != null}',
    );
    if (!_canSplit) {
      _log('openLeft canSplit=false');
      return false;
    }
    // 左右视频页共用同一个播放器实例，先退出右侧残留的全屏状态，
    // 否则新打开的左侧视频页会被全屏态覆盖（只显示播放器）。
    exitRightFullScreen();
    final current = _leftArguments;
    if (current != null) {
      // 已经在播放同一个视频时不重复入栈/压路由，
      // 否则返回时只会弹掉重复项，表现为“闪一下又没变”。
      if (current.arguments['heroTag'] == arguments['heroTag']) {
        _log('openLeft duplicate heroTag ignored');
        return true;
      }
      // 左侧 pane 内继续打开视频时向上堆叠，返回时逐层退出。
      current.videoStack.add(arguments);
      final navigator = _leftSplitNavigatorKey?.currentState;
      if (navigator == null) {
        // pane 尚未挂载：只记录参数，挂载后会用栈顶作为初始路由，
        // 已移动到右侧的 pane 保持在右侧。
        _log('openLeft pane not mounted, stack=${current.videoStack.length}');
      } else {
        _log('openLeft push stack=${current.videoStack.length}');
        navigator.pushNamed('/videoV', arguments: arguments);
      }
    } else {
      _log('openLeft create new left pane');
      _leftArguments = VideoSplitArguments([arguments]);
      // 只有新建左侧 pane 时才默认显示在左侧；
      // 已经移动到右侧的 pane 继续在右侧叠加。
      _leftPaneOnRight = false;
    }
    notifyListeners();
    return true;
  }

  bool moveLeftPaneToRight() {
    _log(
      'moveLeftPaneToRight left=${_leftArguments != null} already=$_leftPaneOnRight',
    );
    if (_leftArguments == null || _leftPaneOnRight) {
      return false;
    }
    // 右侧内容退出，由 left pane 顶替右侧：
    // 保留 left pane 本身（同一个 widget/导航栈），只把它的显示位置、
    // 焦点和导航 key 切到右侧，右侧原内容关闭。
    _leftPaneOnRight = true;
    _arguments = null;
    _displayedArguments = null;
    _rightRouteStack = const [];
    _lastInteractionFromRight = true;
    useLeftNavigatorKey();
    notifyListeners();
    return true;
  }

  /// 左侧独立 pane 返回一层。
  ///
  /// 不走 Navigator.pop（实测 pop 出来的上一层页面会被回滚/不刷新），
  /// 而是按 [VideoSplitArguments.videoStack] 用上一层视频重建这个 pane：
  /// 新的 VideoSplitArguments 会换 id → _VideoSplitPane 状态重建 →
  /// Navigator 的初始路由就是上一层视频，稳定可见。
  bool popLeftVideo() {
    final current = _leftArguments;
    if (current == null || current.videoStack.length <= 1) {
      return false;
    }
    final remaining = List<Map<String, dynamic>>.from(current.videoStack)
      ..removeLast();
    _leftArguments = VideoSplitArguments(remaining);
    _log('popLeftVideo -> stack=${remaining.length} id=${_leftArguments!.id}');
    notifyListeners();
    return true;
  }

  /// 关闭左侧独立 pane；如果它下面还保留着 right pane 就露出来，
  /// 否则返回后由上层结束分屏。
  void closeLeftPane() {
    _log('closeLeftPane onRight=$_leftPaneOnRight');
    if (_leftArguments == null) {
      return;
    }
    // 右侧已经没有 pane 了：关闭 left pane 就等于结束整个分屏，
    // 必须走完整 close()，否则 _restoreRouting()/_locked 等不会被复位，
    // 分屏退出后 GetX 路由状态会残留在 /videoV，导致再点视频打不开。
    if (_arguments == null) {
      close();
      return;
    }
    _leftArguments = null;
    _leftPaneOnRight = false;
    _leftPaneFullScreen = false;
    _lastInteractionFromRight = true;
    if (_splitNavigatorKey == null) {
      useRootNavigatorKey();
    } else {
      useSplitNavigatorKey();
    }
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

  void attachRootNavigatorKey(GlobalKey<NavigatorState> key) {
    _rootNavigatorKey = key;
  }

  void detachRootNavigatorKey(GlobalKey<NavigatorState> key) {
    if (identical(_rootNavigatorKey, key)) {
      _rootNavigatorKey = null;
    }
  }

  void useRootNavigatorKey() {
    final key = _rootNavigatorKey;
    if (key != null && Get.key != key) {
      Get.addKey(key);
    }
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
    if (isOpen && !_locked) {
      _replaceRightStackOnNextPush = true;
    }
  }

  /// 右侧触发的导航保留右侧分屏栈，向上堆叠。
  void markInteractionFromRight() {
    _lastInteractionFromRight = true;
    _replaceRightStackOnNextPush = false;
  }

  bool get isInteractionFromRight => _lastInteractionFromRight;

  bool get isLocked => _locked;

  bool get isStandalonePortrait => _standalonePortrait;

  void setStandalonePortrait(bool value) {
    _standalonePortrait = value;
  }

  bool get isLeftStandaloneFullScreen => _leftStandaloneFullScreen;

  bool get isLeftInlineVideo => _leftInlineVideo;

  bool get isPaneOnLeft => _paneOnLeft;

  void setPaneOnLeft(bool value) {
    if (_paneOnLeft == value) {
      return;
    }
    _paneOnLeft = value;
    if (value) {
      _lastInteractionFromRight = false;
    } else {
      _lastInteractionFromRight = true;
      useSplitNavigatorKey();
    }
    notifyListeners();
  }

  void setLeftInlineVideo(bool value) {
    _leftInlineVideo = value;
  }

  void setLeftStandaloneFullScreen(bool value) {
    if (_leftStandaloneFullScreen == value) {
      return;
    }
    _leftStandaloneFullScreen = value;
    notifyListeners();
  }

  void toggleLock() {
    _locked = !_locked;
    if (!_locked) {
      _leftInlineVideo = false;
      _paneOnLeft = false;
    }
    notifyListeners();
  }

  void useSplitNavigatorKey() {
    final key = _splitNavigatorKey;
    if (key != null && Get.key != key) {
      Get.addKey(key);
    }
  }

  bool consumeReplaceRightStack() {
    final replace = _replaceRightStackOnNextPush;
    _replaceRightStackOnNextPush = false;
    return replace;
  }

  void updateRightRouteStack(List<SplitRouteInfo> stack) {
    _rightRouteStack = stack;
  }

  void updateLeftRouteStack(List<SplitRouteInfo> stack) {
    _leftRouteStack = stack;
  }

  void onRightVideoPopped() {
    final current = _arguments;
    if (current != null && current.videoStack.length > 1) {
      current.videoStack.removeLast();
      _displayedArguments = current.videoStack.last;
    }
  }

  void onLeftVideoPopped() {
    final current = _leftArguments;
    if (current != null && current.videoStack.length > 1) {
      current.videoStack.removeLast();
    }
  }

  /// 优先处理全屏、右侧分屏、右侧 Navigator 和根导航中新压入的页面，
  /// 最后才关闭分屏，避免直接退出。
  Future<void> handleBack() async {
    _log(
      'handleBack enter handling=$_handlingBack right=${_arguments != null} left=${_leftArguments != null} onRight=$_leftPaneOnRight focusRight=$_lastInteractionFromRight locked=$_locked',
    );
    if (_handlingBack) {
      _log('handleBack reentrant ignored');
      return;
    }
    _handlingBack = true;
    try {
      if (_rightFullScreen || _leftPaneFullScreen) {
        final handler = _fullScreenBackHandler;
        if (handler != null && handler()) {
          return;
        }
      }

      // 左侧独立 pane 优先按焦点返回。
      final leftNavigator = _leftSplitNavigatorKey?.currentState;
      if (leftNavigator != null &&
          (_leftPaneOnRight || !_lastInteractionFromRight)) {
        final leftCurrent = _leftArguments;
        final leftTopName = _leftRouteStack.isNotEmpty
            ? _leftRouteStack.last.name
            : null;
        _log(
          'leftPane canPop=${leftNavigator.canPop()} '
          'stack=${leftCurrent?.videoStack.length} top=$leftTopName',
        );
        // 顶层是视频且还有上一层：用重建的方式回到上一层视频，
        // 避免 pop 后旧页面被回滚/不刷新。
        if (leftCurrent != null &&
            leftTopName == '/videoV' &&
            leftCurrent.videoStack.length > 1) {
          popLeftVideo();
          return;
        }
        // 顶层是非视频页（设置/评论等）：正常 pop。
        if (leftNavigator.canPop()) {
          final leftHandled = await leftNavigator.maybePop();
          _log('leftPane maybePop -> $leftHandled');
          if (leftHandled) {
            return;
          }
        }
        // left pane 已经到了最后一层：关闭它。
        // - 还在左侧：露出被它盖住的主界面 + 右侧原视频；
        // - 已被顶到右侧：right pane 已经退出，这里就是结束分屏。
        closeLeftPane();
        return;
      }

      // 焦点在左侧时，返回键优先返回左侧导航栈。
      // 注意：主页面注册了 canPop=false 的 PopScope，若根导航只剩主页面，
      // maybePop() 会返回 true 却什么都不弹，会让返回流程提前结束。
      final leftRootNavigator = _rootNavigator;
      if (!_lastInteractionFromRight &&
          _leftArguments == null &&
          leftRootNavigator != null &&
          leftRootNavigator.canPop()) {
        final leftHandled = await leftRootNavigator.maybePop();
        if (leftHandled) {
          return;
        }
      }

      final navigator = _splitNavigatorKey?.currentState;
      if (navigator != null) {
        // maybePop 会优先处理右侧当前页面内部的 LocalHistoryEntry
        // （评论回复、底部弹层等），不会直接跳过它们关闭分屏。
        final handled = await navigator.maybePop();
        if (handled) {
          return;
        }
      }

      final current = _arguments;
      final rightTopName = _rightRouteStack.isNotEmpty
          ? _rightRouteStack.last.name
          : null;
      if (navigator != null &&
          current != null &&
          rightTopName == '/videoV' &&
          current.videoStack.length > 1) {
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
      if (!_lastInteractionFromRight &&
          rootNavigator != null &&
          rootNavigator.canPop() &&
          rootTop != null &&
          rootTop != _rootTopWhenOpened) {
        rootNavigator.pop();
        return;
      }

      // 右侧内容已经返回到底：如果还有 left pane，就把它顶到右侧，
      // 保留它完整的导航栈与功能，而不是直接把整个分屏关掉。
      if (_leftArguments != null && !_leftPaneOnRight) {
        moveLeftPaneToRight();
        return;
      }
      if (_locked && _moveLeftStackToRight()) {
        _log('handleBack moveLeftStackToRight');
        return;
      }
      _log('handleBack close split');
      close();
    } finally {
      // 一次系统返回会同步调用多次 handleBack（根路由上每个 PopEntry 一次），
      // 这里用 microtask 复位，保证整批同步调用都命中去重；
      // 若用同步复位，一按返回就会连退多层。
      scheduleMicrotask(() {
        _handlingBack = false;
      });
    }
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
    // left pane 被移到右侧后，右侧显示的其实就是 left pane，
    // 此时再创建 right pane 不会被渲染（表现为“打不开新页面”），
    // 直接把新视频压入 left pane。
    if (_leftPaneOnRight) {
      return openLeft(arguments);
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

  /// 锁定状态下右侧全部退出时：
  /// 如果根导航里还打开了内容，则把这些内容整体迁到右侧分屏，
  /// 根页面保持不动；如果根导航只有根页面，则返回 false 交给上层关闭分屏。
  bool _moveLeftStackToRight() {
    final rootNavigator = _rootNavigator ?? Get.key.currentState;
    final targetNavigator = _splitNavigatorKey?.currentState;
    if (rootNavigator == null || targetNavigator == null) {
      return false;
    }
    if (!rootNavigator.canPop()) {
      return false;
    }

    final routeStack = <SplitRouteInfo>[];
    for (final route in _rootRoutes.skip(1)) {
      if (route is! PageRoute) {
        continue;
      }
      final name = _routeNameOf(route);
      if (name == null || name.isEmpty) {
        continue;
      }
      routeStack.add(
        SplitRouteInfo(name: name, arguments: route.settings.arguments),
      );
    }
    if (routeStack.isEmpty) {
      return false;
    }

    rootNavigator.popUntil((route) => route.isFirst);
    for (var i = 0; i < routeStack.length; i++) {
      final route = routeStack[i];
      final name = route.name!;
      if (i == 0) {
        targetNavigator.pushNamedAndRemoveUntil(
          name,
          (route) => false,
          arguments: route.arguments,
        );
      } else {
        targetNavigator.pushNamed(name, arguments: route.arguments);
      }
    }
    _lastInteractionFromRight = true;
    useSplitNavigatorKey();
    return true;
  }

  void close() {
    final hadPane = _arguments != null || _leftArguments != null;
    _log('close hadPane=$hadPane');
    _pendingArguments = null;
    _rightFullScreen = false;
    _displayedArguments = null;
    _rightRouteStack = const [];
    _leftRouteStack = const [];
    _rootNavigator = null;
    _rootTopWhenOpened = null;
    _fullScreenBackOwner = null;
    _fullScreenBackHandler = null;
    _replaceRightStackOnNextPush = false;
    _lastInteractionFromRight = false;
    _locked = false;
    _leftStandaloneFullScreen = false;
    _leftInlineVideo = false;
    _paneOnLeft = false;
    _leftArguments = null;
    _leftPaneOnRight = false;
    _leftPaneFullScreen = false;
    _arguments = null;
    _restoreRouting();
    if (hadPane) {
      notifyListeners();
    }
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
