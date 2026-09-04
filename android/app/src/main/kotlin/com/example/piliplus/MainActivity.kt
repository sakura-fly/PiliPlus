package com.example.piliplus

import android.content.ContentValues
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager.LayoutParams
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : AudioServiceActivity() {
    // 等待用户授权"安装未知应用"后自动继续安装的 APK 路径
    private var pendingApkPath: String? = null

    override fun onResume() {
        super.onResume()
        val path = pendingApkPath
        if (path != null && canInstallUnknownApps()) {
            pendingApkPath = null
            launchInstaller(path)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 更新包 APK：安装 / 导出公共下载 / 打开下载路径
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piliplus/install_apk")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> handleInstallApk(call.argument<String>("path"), result)
                    "exportToDownloads" -> {
                        val src = call.argument<String>("path")
                        val name = call.argument<String>("fileName")
                        if (src.isNullOrEmpty() || name.isNullOrEmpty()) {
                            result.error("bad_args", "path/fileName missing", null)
                        } else {
                            val dst = exportToPublicDownloads(src, name)
                            if (dst == null) {
                                result.error("export_failed", "export to public download failed", null)
                            } else {
                                result.success(dst)
                            }
                        }
                    }
                    "openDownloadsFolder" -> {
                        try {
                            val treeUri = DocumentsContract.buildTreeDocumentUri(
                                "com.android.externalstorage.documents",
                                "primary:${Environment.DIRECTORY_DOWNLOADS}/PiliPlus"
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(treeUri, DocumentsContract.Document.MIME_TYPE_DIR)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // 安装 APK：未授权时记住路径并跳系统设置，返回后 onResume 自动继续安装
    private fun handleInstallApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("bad_args", "path is null or empty", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("file_not_found", "file not found: $path", null)
            return
        }
        if (!canInstallUnknownApps()) {
            pendingApkPath = path
            openInstallUnknownSourcesSettings()
            result.error(
                "install_unknown_sources_required",
                "need to allow install unknown apps",
                null
            )
            return
        }
        launchInstaller(path)
        result.success(true)
    }

    private fun canInstallUnknownApps(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun openInstallUnknownSourcesSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName")
        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        startActivity(intent)
    }

    private fun launchInstaller(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    // 把 APK 复制到公共下载目录 Download/PiliPlus（Android 10+ 走 MediaStore，无需存储权限）
    private fun exportToPublicDownloads(srcPath: String, fileName: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/vnd.android.package-archive")
                    put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/PiliPlus")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return null
                contentResolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(File(srcPath)).use { it.copyTo(out) }
                } ?: return null
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } else {
                val dstDir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    "PiliPlus"
                ).apply { mkdirs() }
                File(srcPath).copyTo(File(dstDir, fileName), overwrite = true)
            }
            File(Environment.getExternalStorageDirectory(), "Download/PiliPlus/$fileName").absolutePath
        } catch (e: Exception) {
            null
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
