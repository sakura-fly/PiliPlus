import 'dart:io' show Directory, File, Platform, Process;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

abstract final class Update {
  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      // Android 走 Gitee（国内快，Gitee 只发布 Android 包）；其他平台走 GitHub
      final bool fromGitee = Platform.isAndroid;
      final res = await Request().get(
        fromGitee ? Api.giteeLatestApp : Api.githubLatestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is Map || res.data.isEmpty) {
        if (!isAuto) {
          SmartDialog.showToast(
              '检查更新失败，${fromGitee ? 'Gitee' : 'GitHub'}接口未返回数据，请检查网络');
        }
        return;
      }
      // Gitee releases 接口按创建时间升序返回（旧版本在前），取最新的一条
      final List releases = res.data as List;
      Map<String, dynamic> data =
          (releases.first as Map).cast<String, dynamic>();
      for (final release in releases) {
        final current = release as Map;
        if (DateTime.parse('${current['created_at']}')
            .isAfter(DateTime.parse('${data['created_at']}'))) {
          data = current.cast<String, dynamic>();
        }
      }
      if (fromGitee) {
        // Gitee 的 release 不内嵌附件，需单独获取附件列表并合并到 assets
        final attachRes = await Request().get(
          '${Api.giteeAttachFiles}${data['id']}/attach_files',
          queryParameters: {'per_page': 100},
          options: Options(
            headers: {'user-agent': BrowserUa.mob},
            extra: {'account': const NoAccount()},
          ),
        );
        data['assets'] = attachRes.data is List ? attachRes.data : [];
      } else {
        // GitHub release 自带 assets 字段
        data['assets'] ??= [];
      }
      // 用版本号(versionCode)判断是否有更新：Release 创建时间总是晚于构建时间，
      // 按 created_at 时间戳比较会导致"已是最新版仍提示更新"的误报
      final String tagName = '${data['tag_name']}';
      final versionCodeMatch = RegExp(r'\+(\d+)\s*$').firstMatch(tagName);
      final int? latestCode =
          versionCodeMatch == null ? null : int.tryParse(versionCodeMatch.group(1)!);
      final bool hasUpdate;
      if (latestCode != null) {
        hasUpdate = latestCode > BuildConfig.versionCode;
      } else {
        // tag 名不含版本号时回退到时间比较
        final int latest =
            DateTime.parse(data['created_at']).millisecondsSinceEpoch ~/ 1000;
        hasUpdate = BuildConfig.buildTime < latest;
      }
      if (!hasUpdate) {
        // 已是最新版本：手动检查时提示，并可重新下载当前版本
        if (!isAuto) {
          final String currentVersion =
              '${BuildConfig.versionName}+${BuildConfig.versionCode}';
          SmartDialog.show(
            animationType: SmartAnimationType.centerFade_otherSlide,
            builder: (context) {
              final colorScheme = ColorScheme.of(context);
              return AlertDialog(
                title: const Text('当前已是最新版本'),
                content: Text('最新版本: $tagName\n当前版本: $currentVersion\n\n是否重新下载安装包？'),
                actions: [
                  TextButton(
                    onPressed: SmartDialog.dismiss,
                    child: Text(
                      '取消',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      SmartDialog.dismiss();
                      showDownloadDialog(data, title: '重新下载安装包');
                    },
                    child: Text(
                      '重新下载',
                      style: TextStyle(color: colorScheme.primary),
                    ),
                  ),
                ],
              );
            },
          );
        }
      } else {
        showDownloadDialog(data, isAuto: isAuto);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  /// 下载安装包弹窗：有新版本或手动重新下载时复用
  static void showDownloadDialog(
    Map data, {
    String? title,
    bool isAuto = false,
  }) {
    final String dialogTitle = title ?? '🎉 发现新版本 ';
    // 仅在自动检测到新版本时提供"不再提醒"
    final bool showNoMoreRemind = isAuto;
    SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        Widget downloadBtn(String text, {String? ext}) => TextButton(
          onPressed: () => onDownload(data, ext: ext),
          child: Text(text),
        );
        return AlertDialog(
          title: Text(dialogTitle),
          content: SizedBox(
            height: 280,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data['tag_name']}',
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 8),
                  Text('${data['body']}'),
                  TextButton(
                    onPressed: () => PageUtils.launchURL(
                      'https://gitee.com/sakura-fly/PiliPlus/commits',
                    ),
                    child: Text(
                      "点此查看完整更新(即commit)内容",
                      style: TextStyle(color: colorScheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (showNoMoreRemind)
              TextButton(
                onPressed: () {
                  SmartDialog.dismiss();
                  GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                },
                child: Text(
                  '不再提醒',
                  style: TextStyle(color: colorScheme.outline),
                ),
              ),
            TextButton(
              onPressed: SmartDialog.dismiss,
              child: Text(
                '取消',
                style: TextStyle(color: colorScheme.outline),
              ),
            ),
            if (Platform.isWindows) ...[
              downloadBtn('zip', ext: 'zip'),
              downloadBtn('exe', ext: 'exe'),
            ] else if (Platform.isLinux) ...[
              downloadBtn('rpm', ext: 'rpm'),
              downloadBtn('deb', ext: 'deb'),
              downloadBtn('targz', ext: 'tar.gz'),
            ] else
              downloadBtn('Gitee'),
          ],
        );
      },
    );
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      // Android：Gitee 通常只发布单一 ABI（如 arm64-v8a），按设备支持的 ABI
      // 依次尝试匹配（arm64-v8a 优先，找不到再试 v7a）；其余平台用操作系统名匹配
      final AndroidDeviceInfo? androidInfo = Platform.isAndroid
          ? await DeviceInfoPlugin().androidInfo
          : null;
      final String plat =
          androidInfo?.supportedAbis.first ?? Platform.operatingSystem;
      Map<String, dynamic>? asset;
      if (androidInfo != null) {
        for (final abi in androidInfo.supportedAbis) {
          asset = findAsset(data, plat: abi, ext: ext);
          if (asset != null) break;
        }
      } else {
        asset = findAsset(data, plat: plat, ext: ext);
      }
      if (asset == null) {
        throw UnsupportedError('platform not found: $plat');
      }
      final String url = asset['browser_download_url'];
      final String fileName = asset['name'];
      // 选择下载方式：跳转浏览器 / App 内直接下载
      SmartDialog.show(
        animationType: SmartAnimationType.centerFade_otherSlide,
        builder: (context) {
          final colorScheme = ColorScheme.of(context);
          return AlertDialog(
            title: const Text('下载安装包'),
            content: Text('$fileName\n\n请选择下载方式：'),
            actions: [
              TextButton(
                onPressed: () {
                  SmartDialog.dismiss();
                  PageUtils.launchURL(url);
                },
                child: const Text('跳转浏览器'),
              ),
              TextButton(
                onPressed: () {
                  SmartDialog.dismiss();
                  downloadInApp(url, fileName);
                },
                child: Text(
                  'App 内直接下载',
                  style: TextStyle(color: colorScheme.primary),
                ),
              ),
              TextButton(
                onPressed: SmartDialog.dismiss,
                child: Text('取消', style: TextStyle(color: colorScheme.outline)),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
      PageUtils.launchURL('https://gitee.com/sakura-fly/PiliPlus/releases');
    }
  }

  /// 在 assets 中查找匹配当前平台/格式的安装包
  static Map<String, dynamic>? findAsset(
    Map data, {
    required String plat,
    String? ext,
  }) {
    final assets = data['assets'];
    if (assets is! List) return null;
    for (final i in assets) {
      if (i is! Map) continue;
      final String name = '${i['name']}';
      if (name.contains(plat) &&
          (ext == null || ext.isEmpty ? true : name.endsWith(ext))) {
        return i.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// App 内直接下载安装包
  static Future<void> downloadInApp(String url, String fileName) async {
    try {
      final bool isAndroid = Platform.isAndroid;
      final Directory dir;
      if (isAndroid) {
        // Android 存应用专属外部目录（无需存储权限，FileProvider 可直接共享给安装器）
        dir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } else {
        // 桌面等其他平台：系统下载目录
        dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
      }
      final String savePath = '${dir.path}${Platform.pathSeparator}$fileName';
      final file = File(savePath);
      if (file.existsSync()) {
        file.deleteSync(); // 避免续传残留导致安装包损坏
      }
      if (isAndroid) {
        // Android：通知栏显示下载进度
        await _updateDownloadNotification(
          title: '正在下载 $fileName',
          body: '0%',
          showProgress: true,
          progress: 0,
        );
      } else {
        SmartDialog.showToast('开始下载: $fileName');
      }
      int lastPercent = -1;
      DownloadManager(
        url: url,
        path: savePath,
        onReceiveProgress: (received, total) {
          if (!isAndroid) return;
          final int percent = total <= 0 ? 0 : received * 100 ~/ total;
          if (percent == lastPercent) return;
          lastPercent = percent;
          _updateDownloadNotification(
            title: '正在下载 $fileName',
            body: '$percent%',
            showProgress: true,
            progress: percent,
          );
        },
        onDone: ([Object? error]) async {
          if (error != null) {
            if (isAndroid) {
              await _updateDownloadNotification(title: '下载失败', body: '$error');
            }
            SmartDialog.showToast('下载失败: $error');
            return;
          }
          if (isAndroid) {
            await _updateDownloadNotification(title: '下载完成', body: fileName);
            // 下载完成：弹窗询问是否安装
            _showInstallDialog(savePath, fileName);
          } else {
            SmartDialog.showToast('下载完成: $savePath');
            if (!Platform.isIOS) {
              openInFolder(savePath);
            }
          }
        },
      );
    } catch (e) {
      SmartDialog.showToast('下载失败: $e');
    }
  }

  /// 在文件管理器中显示下载好的文件（桌面端）
  static Future<void> openInFolder(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', filePath]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [File(filePath).parent.path]);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('open folder error: $e');
    }
  }

  // ---- Android 通知栏下载进度与 APK 安装 ----

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _notificationReady = false;
  static const int _downloadNotifyId = 20240601; // 下载通知 id

  static Future<void> _ensureNotification() async {
    if (_notificationReady) return;
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    if (Platform.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
    _notificationReady = true;
  }

  /// 更新/展示下载通知（Android）
  static Future<void> _updateDownloadNotification({
    required String title,
    String? body,
    bool showProgress = false,
    int progress = 0,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _ensureNotification();
      await _notifications.show(
        _downloadNotifyId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'piliplus_update_download',
            '应用更新下载',
            channelDescription: '应用更新安装包下载进度',
            importance: Importance.low,
            priority: Priority.low,
            showProgress: showProgress,
            maxProgress: 100,
            progress: progress,
            onlyAlertOnce: true,
            ongoing: showProgress,
          ),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('notification error: $e');
    }
  }

  /// 下载完成后弹窗询问是否安装（Android）
  static void _showInstallDialog(String apkPath, String fileName) {
    SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        return AlertDialog(
          title: const Text('下载完成'),
          content: Text('$fileName\n\n是否立即安装？'),
          actions: [
            TextButton(
              onPressed: SmartDialog.dismiss,
              child: Text(
                '取消',
                style: TextStyle(color: colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () async {
                SmartDialog.dismiss();
                final bool ok = await installApk(apkPath);
                if (!ok) {
                  SmartDialog.showToast('无法启动安装，请到系统文件管理器手动安装');
                }
              },
              child: Text(
                '立即安装',
                style: TextStyle(color: colorScheme.primary),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 调原生安装 APK（Android FileProvider）
  static const MethodChannel _installChannel =
      MethodChannel('piliplus/install_apk');

  static Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? ok = await _installChannel.invokeMethod<bool>(
        'installApk',
        {'path': path},
      );
      return ok ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('install apk error: $e');
      return false;
    }
  }
}
