import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app_updater.dart';
import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

/// Displays current app version, GitHub Releases update controls, automatic
/// update toggle, runtime paths, and verification metadata.
class AboutUpdateView extends StatelessWidget {
  const AboutUpdateView({
    super.key,
    required this.controller,
    this.onBeforeRestart,
    this.compact = false,
  });

  final AppUpdateController controller;
  final Future<void> Function()? onBeforeRestart;
  final bool compact;

  String _formatPath(String raw) {
    if (raw.isEmpty) return '初始化中…';
    if (Platform.isMacOS) {
      final match = RegExp(r'^/Users/[^/]+').firstMatch(raw);
      if (match != null) {
        return '~${raw.substring(match.end)}';
      }
    }
    return raw;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _iconBadge(
    BuildContext context, {
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(WRadius.sm),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 17, color: foreground),
    );
  }

  Widget _statusLine(BuildContext context, WColors c) {
    final status = controller.status;
    final release = controller.latestRelease;
    final busy = controller.isBusy;

    IconData icon;
    Color color;
    String text;

    switch (status) {
      case UpdateStatus.checking:
        icon = Icons.sync_rounded;
        color = c.brand;
        text = '正在检查 GitHub Releases…';
        break;
      case UpdateStatus.upToDate:
        icon = Icons.check_circle_rounded;
        color = c.success;
        text = '已是最新版本';
        break;
      case UpdateStatus.available:
        icon = Icons.arrow_circle_up_rounded;
        color = c.brand;
        text = release == null
            ? '发现新版本'
            : '发现新版本 v${release.version.normalized}';
        break;
      case UpdateStatus.downloading:
        icon = Icons.downloading_rounded;
        color = c.brand;
        final progress = controller.downloadProgress;
        final pct = progress == null ? '' : ' ${(progress * 100).round()}%';
        text = '正在下载更新包$pct';
        break;
      case UpdateStatus.verifying:
        icon = Icons.verified_user_outlined;
        color = c.brand;
        text = '正在校验 SHA-256 摘要…';
        break;
      case UpdateStatus.installing:
        icon = Icons.restart_alt_rounded;
        color = c.brand;
        text = '校验通过，正在安装并重启…';
        break;
      case UpdateStatus.error:
        icon = Icons.error_outline_rounded;
        color = c.danger;
        text = controller.errorMessage ?? '更新失败';
        break;
      case UpdateStatus.idle:
        icon = Icons.info_outline_rounded;
        color = c.textSecondary;
        text = '点击右侧按钮检查 GitHub 更新';
        break;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: c.brand,
            ),
          )
        else
          Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: status == UpdateStatus.error
                  ? FontWeight.w500
                  : FontWeight.w400,
              color: status == UpdateStatus.error ? c.danger : c.textSecondary,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  Widget _primaryActionButton(BuildContext context, WColors c) {
    final busy = controller.isBusy;
    if (controller.hasUpdate && controller.canInstallInApp) {
      return FilledButton.icon(
        onPressed: busy
            ? null
            : () => unawaited(
                controller.downloadAndInstallUpdate(
                  beforeRestart: onBeforeRestart,
                ),
              ),
        icon: const Icon(Icons.system_update_alt_rounded, size: 16),
        label: const Text('下载并更新'),
      );
    }
    if (controller.hasUpdate && !controller.canInstallInApp) {
      return OutlinedButton.icon(
        onPressed: busy ? null : () => unawaited(controller.openLatestReleasePage()),
        icon: const Icon(Icons.open_in_new_rounded, size: 15),
        label: const Text('前往下载'),
      );
    }
    return OutlinedButton(
      onPressed: busy
          ? null
          : () => unawaited(controller.checkForUpdates(silent: false)),
      style: OutlinedButton.styleFrom(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      ),
      child: Text(busy ? '检查中…' : '检查更新'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final c = WColors.of(context);
        final release = controller.latestRelease;
        final runtime = controller.runtimeInfo;
        final showProgress =
            controller.status == UpdateStatus.downloading ||
            controller.status == UpdateStatus.verifying ||
            controller.status == UpdateStatus.installing;
        final showReleaseNotes = controller.hasUpdate && release != null;
        final installHint = _installabilityHint();
        final openDirLabel = controller.platform == UpdatePlatform.macos
            ? '在访达中显示'
            : '打开目录';
        final canOpenDir =
            (controller.platform == UpdatePlatform.macos ||
                controller.platform == UpdatePlatform.windows) &&
            controller.dataDirectoryPath.isNotEmpty;

        final cards = <Widget>[
                WSurface(
                  radius: WRadius.lg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final narrow = constraints.maxWidth < 360;
                            final identity = Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: c.surfaceMuted,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: c.border),
                                  ),
                                  alignment: Alignment.center,
                                  child: const WBrandMark(size: 34, radius: 8),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            'Wencrypt',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w700,
                                                  color: c.textPrimary,
                                                ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: c.brandSoft,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    WRadius.pill,
                                                  ),
                                            ),
                                            child: Text(
                                              'v${controller.currentVersion}',
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                                color: c.isDark
                                                    ? const Color(0xFFBBD0FF)
                                                    : c.brand,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      _statusLine(context, c),
                                    ],
                                  ),
                                ),
                              ],
                            );

                            final action = _primaryActionButton(context, c);
                            if (narrow) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  identity,
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: action,
                                  ),
                                ],
                              );
                            }

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(child: identity),
                                const SizedBox(width: 12),
                                action,
                              ],
                            );
                          },
                        ),
                      ),
                      if (showProgress)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  WRadius.pill,
                                ),
                                child: LinearProgressIndicator(
                                  minHeight: 5,
                                  value:
                                      controller.status ==
                                              UpdateStatus.downloading
                                          ? controller.downloadProgress
                                          : null,
                                  backgroundColor: c.surfaceMuted,
                                ),
                              ),
                              if (controller.status ==
                                      UpdateStatus.downloading &&
                                  controller.downloadedBytes > 0) ...[
                                const SizedBox(height: 6),
                                Text(
                                  controller.totalBytes != null &&
                                          controller.totalBytes! > 0
                                      ? '${_formatBytes(controller.downloadedBytes)} / ${_formatBytes(controller.totalBytes!)}'
                                      : _formatBytes(
                                          controller.downloadedBytes,
                                        ),
                                  style: TextStyle(
                                    fontFamily: wMonoFamily,
                                    fontSize: 11.5,
                                    color: c.textTertiary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (showReleaseNotes)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                          child: WSurface(
                            radius: WRadius.md,
                            color: c.surfaceMuted,
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'v${release.version.normalized} 更新说明',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                          color: c.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if (release.assetName != null)
                                      WStatusPill(
                                        label: release.assetName!,
                                        compact: true,
                                      ),
                                  ],
                                ),
                                if (release.notes.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 120,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Text(
                                        release.notes,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.45,
                                          color: c.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                if (installHint != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    installHint,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: c.warning,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      Divider(height: 1, color: c.border),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 14, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '自动检查更新',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w500,
                                      color: c.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '启动时自动检查 GitHub 新版本，仅读取公开版本信息',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: c.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Switch(
                              value: controller.autoCheckEnabled,
                              onChanged: (value) => unawaited(
                                controller.setAutoCheckEnabled(value),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                  child: Text(
                    '运行信息',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textTertiary,
                    ),
                  ),
                ),
                WSurface(
                  radius: WRadius.lg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                        child: Row(
                          children: [
                            _iconBadge(
                              context,
                              icon: Icons.folder_outlined,
                              background: c.warningSoft,
                              foreground: c.warning,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '数据目录',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: c.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatPath(controller.dataDirectoryPath),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: wMonoFamily,
                                      fontSize: 11.5,
                                      color: c.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (canOpenDir) ...[
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: () =>
                                    unawaited(controller.openDataDirectory()),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: c.surface,
                                  foregroundColor: c.textPrimary,
                                  side: BorderSide(color: c.borderStrong),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                                child: Text(openDirLabel),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (runtime.installPath.isNotEmpty) ...[
                        Divider(height: 1, color: c.border),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            children: [
                              _iconBadge(
                                context,
                                icon: Icons.apps_rounded,
                                background: c.brandSoft,
                                foreground: c.brand,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '安装位置',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _formatPath(runtime.installPath),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: wMonoFamily,
                                        fontSize: 11.5,
                                        color: c.textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      Divider(height: 1, color: c.border),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Row(
                          children: [
                            _iconBadge(
                              context,
                              icon: Icons.verified_user_outlined,
                              background: c.successSoft,
                              foreground: c.success,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '更新校验',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: c.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                'SHA-256 强制校验',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: c.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                WSurface(
                  radius: WRadius.lg,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                    child: Row(
                      children: [
                        _iconBadge(
                          context,
                          icon: Icons.inventory_2_outlined,
                          background: c.brandSoft,
                          foreground: c.brand,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'GitHub Releases',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: c.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$kGitHubOwner/$kGitHubRepo',
                                style: TextStyle(
                                  fontFamily: wMonoFamily,
                                  fontSize: 11.5,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () =>
                              unawaited(controller.openReleasesPage()),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: c.surface,
                            foregroundColor: c.textPrimary,
                            side: BorderSide(color: c.borderStrong),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('GitHub'),
                              SizedBox(width: 4),
                              Icon(Icons.north_east_rounded, size: 13),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ];

        final content = ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cards,
          ),
        );
        if (compact) return content;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
          child: Align(
            alignment: Alignment.topCenter,
            child: content,
          ),
        );
      },
    );
  }

  String? _installabilityHint() {
    final release = controller.latestRelease;
    if (!controller.hasUpdate || release == null) return null;
    if (controller.platform == UpdatePlatform.android) {
      return 'Android 端请前往 GitHub Releases 下载并安装签名 APK。';
    }
    if (!controller.runtimeInfo.canAutoInstall) {
      if (controller.runtimeInfo.isSandboxed) {
        return '当前为旧版沙盒构建，本次需前往下载替换；升级到新版后将支持一键自动更新且无需手动执行 xattr。';
      }
      return '当前安装目录只读或正在磁盘映像中运行，请点击「前往下载」手动更新。';
    }
    if (!release.canInstallAsset || release.sha256AssetUrl == null) {
      return '该版本暂未附带可用于自动更新的安装包或 SHA256SUMS.txt，请前往 GitHub 下载更新。';
    }
    return null;
  }
}
