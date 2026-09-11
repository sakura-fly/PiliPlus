import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 平板分屏模式下，右侧视频页的参数。
class VideoSplitArguments {
  VideoSplitArguments(this.arguments) : id = _nextId++;

  static int _nextId = 0;

  final Map<String, dynamic> arguments;
  final int id;
}

/// 管理平板分屏状态。
///
/// 打开后，[TabletSplitScreenHost] 会把当前 App 压缩到左侧，并在右侧
/// 创建独立的视频页。这样用户可以在不离开当前列表的情况下观看视频。
class TabletSplitController extends ChangeNotifier {
  TabletSplitController._();

  static final TabletSplitController instance = TabletSplitController._();

  VideoSplitArguments? _arguments;
  Map<String, dynamic>? _pendingArguments;
  Size? _screenSize;
  GlobalKey<NavigatorState>? _splitNavigatorKey;

  // 打开分屏时暂存根路由的 GetX 状态，关闭分屏后恢复。
  String? _rootCurrent;
  String? _rootPrevious;
  dynamic _rootArgs;
  Map<String, String?>? _rootParameters;
  bool _hasSavedRouting = false;

  VideoSplitArguments? get current => _arguments;

  void updateScreenSize(Size size) {
    _screenSize = size;
  }

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

  /// 优先返回右侧分屏内容；右侧没有可返回内容时关闭分屏。
  void handleBack() {
    final navigator = _splitNavigatorKey?.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
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
        return screenSize.width >= 600;
      }
      return DeviceUtils.size.width >= 600;
    } catch (_) {
      return false;
    }
  }

  /// 尝试在右侧打开视频。返回 false 表示当前环境不应使用分屏。
  bool open(Map<String, dynamic> arguments) {
    if (!_canSplit) {
      return false;
    }
    final current = _arguments;
    if (current != null &&
        current.arguments['heroTag'] == arguments['heroTag']) {
      return true;
    }

    // 切换视频时先移除旧分屏，等旧页面完成 dispose 后再创建新页面，
    // 避免两个视频页在同一帧争用同一个播放器实例。
    if (current != null) {
      _pendingArguments = arguments;
      _arguments = null;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pendingArguments = _pendingArguments;
        if (pendingArguments == null || !Pref.tabletSplitScreen) {
          return;
        }
        _pendingArguments = null;
        _arguments = VideoSplitArguments(pendingArguments);
        notifyListeners();
      });
      return true;
    }

    _saveRouting();
    _pendingArguments = null;
    _arguments = VideoSplitArguments(arguments);
    notifyListeners();
    return true;
  }

  void close() {
    _pendingArguments = null;
    if (_arguments == null) {
      _restoreRouting();
      return;
    }
    _arguments = null;
    _restoreRouting();
    notifyListeners();
  }
}
