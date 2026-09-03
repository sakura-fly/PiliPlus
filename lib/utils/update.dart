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
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

abstract final class Update {
  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is Map || res.data.isEmpty) {
        if (!isAuto) {
          SmartDialog.showToast('检查更新失败，Gitee接口未返回数据，请检查网络');
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
      // gitee 的 release 不内嵌附件，需单独获取附件列表并合并到 assets
      final attachRes = await Request().get(
        '${Api.giteeAttachFiles}${data['id']}/attach_files',
        queryParameters: {'per_page': 100},
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      data['assets'] = attachRes.data is List ? attachRes.data : [];
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
        if (!isAuto) {
          SmartDialog.showToast(
              '已是最新版本: $tagName, 当前版本: ${BuildConfig.versionName}+${BuildConfig.versionCode}');
        }
      } else {
        SmartDialog.show(
          animationType: SmartAnimationType.centerFade_otherSlide,
          builder: (context) {
            final colorScheme = ColorScheme.of(context);
            Widget downloadBtn(String text, {String? ext}) => TextButton(
              onPressed: () => onDownload(data, ext: ext),
              child: Text(text),
            );
            return AlertDialog(
              title: const Text('🎉 发现新版本 '),
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
                if (isAuto)
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
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      final String plat = Platform.isAndroid
          ? (await DeviceInfoPlugin().androidInfo).supportedAbis.first
          : Platform.operatingSystem;
      final asset = findAsset(data, plat: plat, ext: ext);
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
  static void downloadInApp(String url, String fileName) {
    Future<void> run() async {
      try {
        // 优先系统下载目录（桌面/Android 公共下载），不可用时回退应用文档目录
        final Directory dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final String savePath = '${dir.path}${Platform.pathSeparator}$fileName';
        final file = File(savePath);
        if (file.existsSync()) {
          file.deleteSync(); // 避免续传残留导致安装包损坏
        }
        SmartDialog.showToast('开始下载: $fileName');
        DownloadManager(
          url: url,
          path: savePath,
          onReceiveProgress: (received, total) {},
          onDone: ([Object? error]) {
            if (error != null) {
              SmartDialog.showToast('下载失败: $error');
              return;
            }
            SmartDialog.showToast('下载完成: $savePath');
            if (!Platform.isAndroid && !Platform.isIOS) {
              openInFolder(savePath);
            }
          },
        );
      } catch (e) {
        SmartDialog.showToast('下载失败: $e');
      }
    }

    run();
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
}
