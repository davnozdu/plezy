import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/services/linux_self_updater.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linux_self_updater_test');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<Directory> writeBundle(String path, String version) async {
    final dir = await Directory(path).create(recursive: true);
    await File(p.join(path, 'plezy')).writeAsString('binary $version');
    await File(p.join(path, 'plezy.sh')).writeAsString('wrapper $version');
    await File(p.join(path, 'lib', 'libmpv.so.2')).create(recursive: true);
    await File(p.join(path, 'lib', 'libmpv.so.2')).writeAsString('mpv $version');
    await File(p.join(path, 'data', 'icudtl.dat')).create(recursive: true);
    await File(p.join(path, 'data', 'icudtl.dat')).writeAsString('data $version');
    return dir;
  }

  Future<File> packBundle(String version) async {
    final bundle = await writeBundle(p.join(root.path, 'build-$version'), version);
    final archive = File(p.join(root.path, 'plezy-linux-x64-x11-$version.tar.gz'));
    final names = bundle.listSync().map((entry) => p.basename(entry.path)).toList();
    final result = await Process.run('tar', ['-czf', archive.path, '-C', bundle.path, ...names]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return archive;
  }

  String read(Directory dir, String relative) => File(p.join(dir.path, relative)).readAsStringSync();

  test('replaces the bundle in place and keeps the replaced copy', () async {
    // A bundle unpacked loose into a shared folder: its neighbours must survive.
    final install = await writeBundle(p.join(root.path, 'Downloads'), '1');
    await File(p.join(install.path, 'holiday.jpg')).writeAsString('photo');

    await LinuxSelfUpdater.install(await packBundle('2'), install);

    expect(read(install, 'plezy'), 'binary 2');
    expect(read(install, 'lib/libmpv.so.2'), 'mpv 2');
    expect(read(install, 'data/icudtl.dat'), 'data 2');
    expect(read(install, 'holiday.jpg'), 'photo');
    final previous = Directory(p.join(install.path, LinuxSelfUpdater.previousDirName));
    expect(read(previous, 'plezy'), 'binary 1');
    expect(read(previous, 'lib/libmpv.so.2'), 'mpv 1');
    expect(previous.listSync().map((e) => p.basename(e.path)), isNot(contains('holiday.jpg')));
    expect(Directory(p.join(install.path, LinuxSelfUpdater.stagingDirName)).existsSync(), isFalse);
  });

  test('keeps exactly one previous copy across updates', () async {
    final install = await writeBundle(p.join(root.path, 'Plezy'), '1');

    await LinuxSelfUpdater.install(await packBundle('2'), install);
    await LinuxSelfUpdater.install(await packBundle('3'), install);

    expect(read(install, 'plezy'), 'binary 3');
    final previous = Directory(p.join(install.path, LinuxSelfUpdater.previousDirName));
    expect(read(previous, 'plezy'), 'binary 2');
    expect(root.listSync().where((e) => p.basename(e.path).contains('previous')), isEmpty);
  });

  test('a broken archive leaves the install untouched', () async {
    final install = await writeBundle(p.join(root.path, 'Plezy'), '1');
    final broken = File(p.join(root.path, 'broken.tar.gz'))..writeAsStringSync('not a tarball');

    await expectLater(LinuxSelfUpdater.install(broken, install), throwsA(anything));

    expect(read(install, 'plezy'), 'binary 1');
    expect(read(install, 'lib/libmpv.so.2'), 'mpv 1');
    expect(Directory(p.join(install.path, LinuxSelfUpdater.stagingDirName)).existsSync(), isFalse);
  });

  test('an archive that is not a Plezy bundle is refused', () async {
    final install = await writeBundle(p.join(root.path, 'Plezy'), '1');
    final other = await Directory(p.join(root.path, 'other')).create();
    await File(p.join(other.path, 'readme.txt')).writeAsString('hello');
    final archive = File(p.join(root.path, 'other.tar.gz'));
    await Process.run('tar', ['-czf', archive.path, '-C', other.path, 'readme.txt']);

    await expectLater(LinuxSelfUpdater.install(archive, install), throwsStateError);

    expect(read(install, 'plezy'), 'binary 1');
    expect(File(p.join(install.path, 'readme.txt')).existsSync(), isFalse);
  });

  test('verify checks the size and the SHA-256 digest', () async {
    final file = File(p.join(root.path, 'asset.tar.gz'))..writeAsStringSync('payload');
    final digest = sha256.convert('payload'.codeUnits).toString();
    LinuxUpdateAsset asset({int size = 7, String? sha}) =>
        LinuxUpdateAsset(name: 'asset.tar.gz', url: 'https://example.invalid', size: size, sha256: sha);

    await LinuxSelfUpdater.verify(file, asset(sha: digest));
    await LinuxSelfUpdater.verify(file, asset());
    await expectLater(LinuxSelfUpdater.verify(file, asset(size: 8)), throwsStateError);
    await expectLater(LinuxSelfUpdater.verify(file, asset(sha: '0' * 64)), throwsStateError);
  });

  test('picks the Linux x64 tarball from the release assets', () {
    final asset = LinuxUpdateAsset.fromReleaseAssets([
      {'name': 'plezy-windows-x64.zip', 'browser_download_url': 'https://w', 'size': 1},
      {'name': 'plezy-linux-x64-x11.tar.gz', 'browser_download_url': 'https://l', 'size': 42, 'digest': 'sha256:abc'},
    ]);

    expect(asset?.url, 'https://l');
    expect(asset?.size, 42);
    expect(asset?.sha256, 'abc');
    expect(LinuxUpdateAsset.fromReleaseAssets(null), isNull);
    expect(LinuxUpdateAsset.fromReleaseAssets([]), isNull);
  });
}
