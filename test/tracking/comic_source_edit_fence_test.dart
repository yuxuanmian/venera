import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';
import 'package:venera/pages/comic_source_page.dart';

void main() {
  test('cancelling an unchanged custom editor has no file or fence effect', () {
    final file = File('${Directory.systemTemp.path}/venera-editor-test.js');
    file.writeAsStringSync('initial');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    var commits = 0;
    final session = ComicSourceEditSession(
      file: file,
      initialValue: file.readAsStringSync(),
      onCommit: () => commits++,
    );

    session.close();

    expect(file.readAsStringSync(), 'initial');
    expect(commits, 0);
    expect(shouldCommitComicSourceEdit('initial', 'initial'), isFalse);
  });

  test(
    'a changed editor buffer fences the exact custom or managed artifact',
    () {
      final file = File('${Directory.systemTemp.path}/venera-editor-test-2.js');
      file.writeAsStringSync('initial');
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final generations = RuntimeGenerationController();
      const custom = TrustedArtifact(
        sourceKey: 'custom',
        fileName: 'custom.js',
      );
      const managed = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');
      generations.activateIfChanged(
        artifact: custom,
        revision: 'local',
        strategy: TrackingStrategy.local,
      );
      generations.activateIfChanged(
        artifact: managed,
        revision: 'revision-1',
        strategy: TrackingStrategy.cloud,
      );
      final customToken = generations.capture(custom);
      final managedToken = generations.capture(managed);
      var fencedBeforeWrite = false;
      final session = ComicSourceEditSession(
        file: file,
        initialValue: file.readAsStringSync(),
        onBeforeWrite: () {
          expect(file.readAsStringSync(), 'initial');
          fencedBeforeWrite = true;
        },
        onCommit: () {
          expect(fencedBeforeWrite, isTrue);
          expect(file.readAsStringSync(), 'edited');
          generations.invalidate(custom);
          generations.invalidate(managed);
        },
      );

      session.current = 'edited';
      session.close();

      expect(file.readAsStringSync(), 'edited');
      expect(fencedBeforeWrite, isTrue);
      expect(generations.canCommit(customToken), isFalse);
      expect(generations.canCommit(managedToken), isFalse);
      expect(shouldCommitComicSourceEdit('initial', 'edited'), isTrue);
    },
  );

  test('an expired artifact cannot invalidate a newer sibling selection', () {
    final generations = RuntimeGenerationController();
    const first = TrustedArtifact(sourceKey: 'same-key', fileName: 'first.js');
    const second = TrustedArtifact(
      sourceKey: 'same-key',
      fileName: 'second.js',
    );
    generations.activateIfChanged(
      artifact: first,
      revision: 'revision-1',
      strategy: TrackingStrategy.local,
    );
    generations.activateIfChanged(
      artifact: second,
      revision: 'revision-2',
      strategy: TrackingStrategy.cloud,
    );
    final firstToken = generations.capture(first);
    final secondToken = generations.capture(second);

    generations.invalidate(first);

    expect(generations.canCommit(firstToken), isFalse);
    expect(generations.canCommit(secondToken), isTrue);
    expect(generations.current(second)?.revision, 'revision-2');
  });
}
