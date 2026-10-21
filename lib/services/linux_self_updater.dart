import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A release asset the portable Linux build can install itself from.
class LinuxUpdateAsset {
  const LinuxUpdateAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name;
  final String url;
  final int size;

  /// Hex SHA-256 from the release's asset digest, when GitHub reported one.
  final String? sha256;

  /// Picks the Linux x64 tarball out of a GitHub release's `assets` list.
  static LinuxUpdateAsset? fromReleaseAssets(Object? assets) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      final size = asset['size'];
      if (name is! String || url is! String || size is! int) continue;
      if (!name.contains('linux-x64') || !name.endsWith('.tar.gz')) continue;
      final digest = asset['digest'];
      return LinuxUpdateAsset(
        name: name,
        url: url,
        size: size,
        sha256: digest is String && digest.startsWith('sha256:') ? digest.substring('sha256:'.length) : null,
      );
    }
    return null;
  }
}

/// In-place update of the portable Linux tarball install.
///
/// The install directory is wherever the running binary lives (Downloads,
/// Documents, a Steam Deck games folder...), found from the executable rather
/// than configured. The tarball is downloaded to the system temp directory,
/// unpacked into a staging folder inside the install directory (same
/// filesystem, so every swap is a rename), and then each top-level entry of the
/// bundle replaces its counterpart. Only names the bundle itself carries are
/// touched, so a bundle unpacked loose into a shared folder is safe. The
/// replaced entries are kept in [previousDirName] - exactly one previous copy,
/// overwritten by the next update.
///
/// Renaming over a running binary and its loaded libraries is safe on Linux:
/// the process keeps the old inodes until it exits.
class LinuxSelfUpdater {
  static const String stagingDirName = '.plezy-update';
  static const String previousDirName = '.plezy-previous';

  /// Directory of the running bundle, or null when this is not a portable
  /// tarball install (a distro package, a debug run).
  static Directory? get installDirectory {
    if (!Platform.isLinux) return null;
    final dir = File(Platform.resolvedExecutable).parent;
    return looksLikeBundle(dir) ? dir : null;
  }

  static bool get isSupported => installDirectory != null;

  static bool looksLikeBundle(Directory dir) =>
      File(p.join(dir.path, 'plezy')).existsSync() &&
      Directory(p.join(dir.path, 'lib')).existsSync() &&
      Directory(p.join(dir.path, 'data')).existsSync();

  /// Downloads [asset] into a fresh temp directory and verifies its size and,
  /// when known, its SHA-256. The caller deletes the file's parent when done.
  static Future<File> download(LinuxUpdateAsset asset, {void Function(double progress)? onProgress}) async {
    final dir = await Directory.systemTemp.createTemp('plezy-update-');
    final file = File(p.join(dir.path, asset.name));
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(asset.url))).close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download returned HTTP ${response.statusCode}', uri: Uri.parse(asset.url));
      }
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (asset.size > 0) onProgress?.call((received / asset.size).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      await verify(file, asset);
      return file;
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> verify(File file, LinuxUpdateAsset asset) async {
    final length = await file.length();
    if (length != asset.size) {
      throw StateError('Downloaded ${asset.name} is $length bytes, expected ${asset.size}');
    }
    final expected = asset.sha256;
    if (expected == null) return;
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw StateError('Checksum mismatch for ${asset.name}');
    }
  }

  /// Unpacks [archive] over the bundle in [installDir]. On any failure the
  /// install is left as it was.
  static Future<void> install(File archive, Directory installDir) async {
    final staging = Directory(p.join(installDir.path, stagingDirName));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    try {
      final result = await Process.run('tar', ['-xzf', archive.path, '-C', staging.path]);
      if (result.exitCode != 0) {
        throw ProcessException('tar', ['-xzf', archive.path], '${result.stderr}'.trim(), result.exitCode);
      }
      if (!looksLikeBundle(staging)) {
        throw StateError('${p.basename(archive.path)} is not a Plezy Linux bundle');
      }
      final names = await staging.list().map((entry) => p.basename(entry.path)).toList();

      final previous = Directory(p.join(installDir.path, previousDirName));
      if (await previous.exists()) await previous.delete(recursive: true);
      await previous.create();

      final movedAside = <String>[];
      final installed = <String>[];
      try {
        for (final name in names) {
          final current = p.join(installDir.path, name);
          if (await FileSystemEntity.type(current, followLinks: false) != FileSystemEntityType.notFound) {
            await _rename(current, p.join(previous.path, name));
            movedAside.add(name);
          }
          await _rename(p.join(staging.path, name), current);
          installed.add(name);
        }
      } catch (_) {
        for (final name in installed.reversed) {
          await _delete(p.join(installDir.path, name));
        }
        for (final name in movedAside.reversed) {
          await _rename(p.join(previous.path, name), p.join(installDir.path, name));
        }
        rethrow;
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Starts the freshly installed build and exits this one. Goes through the
  /// wrapper script when the bundle has one, since it sets up the library
  /// paths the binary expects.
  static Future<Never> relaunch(Directory installDir) async {
    final wrapper = File(p.join(installDir.path, 'plezy.sh'));
    final executable = await wrapper.exists() ? wrapper.path : p.join(installDir.path, 'plezy');
    await Process.start(executable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  static Future<void> _rename(String from, String to) async {
    switch (await FileSystemEntity.type(from, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(from).rename(to);
      case FileSystemEntityType.link:
        await Link(from).rename(to);
      default:
        await File(from).rename(to);
    }
  }

  static Future<void> _delete(String path) async {
    switch (await FileSystemEntity.type(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(path).delete();
      default:
        await File(path).delete();
    }
  }
}
