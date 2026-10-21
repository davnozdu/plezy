import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/linux_self_updater.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'app_logger.dart';
import 'dialogs.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  final linuxAsset = updateInfo['linuxAsset'] as LinuxUpdateAsset?;
  final installDir = linuxAsset != null ? LinuxSelfUpdater.installDirectory : null;
  return showScopedDialog<void>(
    context: context,
    // A dismissed dialog would not stop a running download or install.
    barrierDismissible: installDir == null,
    builder: (dialogContext) => _UpdateDialog(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
      linuxAsset: installDir != null ? linuxAsset : null,
      installDir: installDir,
    ),
  );
}

enum _InstallStage { idle, downloading, installing, done, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    required this.showSkipVersion,
    required this.linuxAsset,
    required this.installDir,
  });

  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;
  final LinuxUpdateAsset? linuxAsset;
  final Directory? installDir;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _InstallStage _stage = _InstallStage.idle;
  double _progress = 0;
  String? _error;

  String get _latestVersion => widget.updateInfo['latestVersion'] as String;

  bool get _busy => _stage == _InstallStage.downloading || _stage == _InstallStage.installing;

  Future<void> _install() async {
    final asset = widget.linuxAsset!;
    final installDir = widget.installDir!;
    setState(() {
      _stage = _InstallStage.downloading;
      _progress = 0;
      _error = null;
    });
    File? archive;
    try {
      archive = await LinuxSelfUpdater.download(
        asset,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) setState(() => _stage = _InstallStage.installing);
      await LinuxSelfUpdater.install(archive, installDir);
      if (mounted) setState(() => _stage = _InstallStage.done);
    } catch (error, stackTrace) {
      appLogger.e('Failed to install update', error: error, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _stage = _InstallStage.failed;
          _error = '$error';
        });
      }
    } finally {
      if (archive != null) {
        try {
          await archive.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _openRelease() async {
    final url = Uri.parse(widget.updateInfo['releaseUrl'] as String);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.pop(context);
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    switch (_stage) {
      case _InstallStage.idle:
        return const SizedBox.shrink();
      case _InstallStage.downloading:
        return Column(
          crossAxisAlignment: .start,
          children: [
            Text(t.update.downloading(percent: (_progress * 100).round())),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
          ],
        );
      case _InstallStage.installing:
        return Column(
          crossAxisAlignment: .start,
          children: [Text(t.update.installing), const SizedBox(height: 8), const LinearProgressIndicator()],
        );
      case _InstallStage.done:
        return Text(t.update.installed(version: _latestVersion));
      case _InstallStage.failed:
        return Text(
          t.update.installFailed(error: _error ?? ''),
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
        );
    }
  }

  List<Widget> _actions() {
    if (_busy) return const [];
    if (_stage == _InstallStage.done) {
      return [
        DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.later),
        DialogActionButton(
          onPressed: () => LinuxSelfUpdater.relaunch(widget.installDir!),
          label: t.update.restart,
          isPrimary: true,
        ),
      ];
    }
    final canInstall = widget.linuxAsset != null && _stage == _InstallStage.idle;
    return [
      DialogActionButton(onPressed: () => Navigator.pop(context), label: widget.dismissLabel),
      if (widget.showSkipVersion && _stage == _InstallStage.idle)
        DialogActionButton(
          onPressed: () async {
            await UpdateService.skipVersion(_latestVersion);
            if (mounted) Navigator.pop(context);
          },
          label: t.update.skipVersion,
        ),
      if (canInstall)
        DialogActionButton(onPressed: _install, label: t.update.install, isPrimary: true)
      else
        DialogActionButton(onPressed: _openRelease, label: t.update.viewRelease, isPrimary: true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t.update.currentVersion(version: widget.updateInfo['currentVersion']),
              style: theme.textTheme.bodySmall,
            ),
            if (_stage != _InstallStage.idle) ...[const SizedBox(height: 16), _status(context)],
          ],
        ),
        actions: _actions(),
      ),
    );
  }
}
