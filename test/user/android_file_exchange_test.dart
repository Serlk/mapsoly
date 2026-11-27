import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/user/file_exchange.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mapsoly-android'));
  tearDown(() => root.deleteSync(recursive: true));

  test('exports go to a Mapsoly folder in the app\'s shared storage', () async {
    final files = AndroidFileExchange(
      root: () async => root.path,
      now: () => DateTime(2026, 11, 27),
    );
    final dir = await files.exportDirectory();
    expect(dir.path, '${root.path}/Mapsoly');
    expect(dir.existsSync(), isTrue);

    final first = await files.newExportFile('places', 'gpx');
    expect(first.path, '${dir.path}/places-2026-11-27.gpx');
    first.writeAsStringSync('x');
    final second = await files.newExportFile('places', 'gpx');
    expect(second.path, '${dir.path}/places-2026-11-27-2.gpx');

    expect(files.exportFolderLabel, endsWith('/files/Mapsoly'));
    expect(files.canReveal, isFalse);
    expect(await files.reveal(), isFalse);
  });

  test('no shared storage is a file error, not a crash', () async {
    final files = AndroidFileExchange(root: () async => null);
    await expectLater(
      files.exportDirectory(),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      files.newExportFile('places', 'gpx'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
