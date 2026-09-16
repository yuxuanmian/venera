import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/semantic_search/models.dart';
import 'package:venera/foundation/semantic_search/request_scope.dart';
import 'package:venera/foundation/semantic_search/source_resolver.dart';

/// A published-shaped source built directly, so the resolver can be exercised
/// without a JavaScript runtime.
ComicSource resolverSource({
  required String key,
  SemanticSearchData? semantic,
  SearchPageData? search,
}) => ComicSource(
  'Resolver source',
  key,
  null,
  null,
  null,
  null,
  const [],
  search,
  null,
  (id) async => Res<ComicDetails>.error('unused'),
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
  semanticSearchData: semantic,
);

SemanticInvocationSnapshot snapshot({
  SemanticContinuation? input,
  int generation = 1,
  List<String> options = const ['dd'],
}) => SemanticInvocationSnapshot(
  query: SemanticQuery(
    sourceKey: 'resolver_source',
    value: '  Opaque Tag  ',
    options: options,
  ),
  inputContinuation: input,
  generation: generation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The Host-generated semantic error messages are translated; the library
  // must be loaded before any of them can be produced.
  setUpAll(AppTranslation.init);

  group('capability resolution', () {
    test('a valid tagSearch is exact', () {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_exact',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[], subData: 3),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);
      expect(resolver.mode, SemanticCapabilityMode.exactTag);
    });

    test('a tagSearch without any usable loader is not exact', () {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_empty_tag',
          semantic: const SemanticSearchData(null, null),
          search: SearchPageData(
            null,
            (keyword, page, options) async => const Res(<Comic>[]),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);
      expect(resolver.mode, SemanticCapabilityMode.ordinaryFallback);
    });

    test(
      'an ordinary page loader becomes the compatibility fallback',
      () async {
        final calls = <String>[];
        final resolver = ComicSourceSemanticResolver(
          resolverSource(
            key: 'resolver_ordinary_page',
            search: SearchPageData(null, (keyword, page, options) async {
              calls.add('$keyword|${options.join(',')}|$page');
              return const Res(<Comic>[], subData: 1);
            }, null),
          ),
        );
        addTearDown(resolver.dispose);
        expect(resolver.mode, SemanticCapabilityMode.ordinaryFallback);

        final scope = SemanticSearchRequestScope();
        final result = await resolver.load(snapshot(), scope);
        expect(result.error, isFalse);
        expect(calls, ['  Opaque Tag  |dd|1']);
      },
    );

    test('nothing usable is unsupported and loads nothing', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(key: 'resolver_unsupported'),
      );
      addTearDown(resolver.dispose);
      expect(resolver.mode, SemanticCapabilityMode.unsupported);

      final result = await resolver.load(
        snapshot(),
        SemanticSearchRequestScope(),
      );
      expect(result.error, isTrue);
    });
  });

  group('page adapter', () {
    test('starts at the ordinary first page and advances by maxPage', () async {
      final pages = <int>[];
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_page_advance',
          semantic: SemanticSearchData((
            value,
            options,
            page, {
            required requestScope,
          }) async {
            pages.add(page);
            return const Res(<Comic>[], subData: 4);
          }, null),
        ),
      );
      addTearDown(resolver.dispose);

      final first = await resolver.load(
        snapshot(),
        SemanticSearchRequestScope(),
      );
      expect(first.error, isFalse);
      expect(pages, [1]);
      expect(first.data.next, const PageContinuation(2, 4));

      final second = await resolver.load(
        snapshot(input: const PageContinuation(2, 4)),
        SemanticSearchRequestScope(),
      );
      expect(pages, [1, 2]);
      expect(second.data.next, const PageContinuation(3, 4));
    });

    test('an empty page before maxPage does not terminate', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_page_sparse',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[], subData: 6),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(input: const PageContinuation(3, 6)),
        SemanticSearchRequestScope(),
      );
      expect(result.error, isFalse);
      expect(result.data.comics, isEmpty);
      expect(result.data.next, const PageContinuation(4, 6));
    });

    test('the declared last page terminates', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_page_end',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[], subData: 3),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(input: const PageContinuation(3, 3)),
        SemanticSearchRequestScope(),
      );
      expect(result.data.next, isNull);
    });

    test('a source without a declared limit keeps advancing', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_page_unbounded',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[]),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(input: const PageContinuation(9, null)),
        SemanticSearchRequestScope(),
      );
      expect(result.data.next, const PageContinuation(10, null));
    });

    test('a non-integer maxPage is rejected instead of guessed', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_page_bad_limit',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[], subData: 'many'),
            null,
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(),
        SemanticSearchRequestScope(),
      );
      expect(result.error, isTrue);
    });
  });

  group('cursor adapter', () {
    test('the first call passes null and the cursor stays opaque', () async {
      final received = <String?>[];
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_cursor',
          semantic: SemanticSearchData(null, (
            value,
            options,
            next, {
            required requestScope,
          }) async {
            received.add(next);
            return const Res(<Comic>[], subData: '  c-1 é  ');
          }),
        ),
      );
      addTearDown(resolver.dispose);

      final first = await resolver.load(
        snapshot(),
        SemanticSearchRequestScope(),
      );
      expect(first.error, isFalse);
      expect(received, [null]);
      expect(first.data.next, const CursorContinuation('  c-1 é  '));

      final second = await resolver.load(
        snapshot(input: const CursorContinuation('  c-1 é  ')),
        SemanticSearchRequestScope(),
      );
      expect(received, [null, '  c-1 é  ']);
      expect(second.data.next, const CursorContinuation('  c-1 é  '));
    });

    test('a null cursor output terminates', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_cursor_end',
          semantic: SemanticSearchData(
            null,
            (value, options, next, {required requestScope}) async =>
                const Res(<Comic>[]),
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(input: const CursorContinuation('c1')),
        SemanticSearchRequestScope(),
      );
      expect(result.data.next, isNull);
    });

    test('a non-string cursor is rejected', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_cursor_bad',
          semantic: SemanticSearchData(
            null,
            (value, options, next, {required requestScope}) async =>
                const Res(<Comic>[], subData: 7),
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(),
        SemanticSearchRequestScope(),
      );
      expect(result.error, isTrue);
    });

    test('a cursor loader never receives a page continuation', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_cursor_mismatch',
          semantic: SemanticSearchData(
            null,
            (value, options, next, {required requestScope}) async =>
                const Res(<Comic>[]),
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.load(
        snapshot(input: const PageContinuation(2, null)),
        SemanticSearchRequestScope(),
      );
      expect(result.error, isTrue);
    });
  });

  group('scope isolation', () {
    test('a canceled scope is visible to the ordinary loader', () async {
      SemanticSearchRequestScope? observed;
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_scope_canceled',
          search: SearchPageData(null, (keyword, page, options) async {
            observed = SemanticSearchRequestScope.current;
            return const Res(<Comic>[]);
          }, null),
        ),
      );
      addTearDown(resolver.dispose);

      final canceled = SemanticSearchRequestScope()..cancel();
      await resolver.load(snapshot(), canceled);
      expect(observed, isNotNull);
      expect(observed!.isCanceled, isTrue);

      final live = SemanticSearchRequestScope();
      await resolver.load(snapshot(), live);
      expect(observed!.isCanceled, isFalse);
      expect(identical(observed, live), isTrue);
    });

    test('two scopes never observe each other', () async {
      final first = SemanticSearchRequestScope();
      final second = SemanticSearchRequestScope();
      first.cancel();
      expect(first.isCanceled, isTrue);
      expect(second.isCanceled, isFalse);
      expect(second.ownedTokenCount, 0);
    });
  });

  group('source assembly lifecycle', () {
    test('a revision bump notifies once and increments the revision', () {
      final assembly = _TestNotifier();
      addTearDown(assembly.dispose);
      var revision = 5;
      final resolver = ComicSourceSemanticResolver(
        resolverSource(key: 'resolver_lifecycle'),
        assemblyLifecycle: assembly,
        assemblyRevision: () => revision,
      );
      addTearDown(resolver.dispose);

      var notifications = 0;
      resolver.lifecycle.addListener(() => notifications++);
      final before = resolver.revision;

      revision = 6;
      assembly.notify();
      expect(notifications, 1);
      expect(resolver.revision, greaterThan(before));

      // An unchanged assembly identity must not invalidate anything.
      assembly.notify();
      expect(notifications, 1);
      expect(resolver.revision, greaterThan(before));
    });

    test('dispose detaches the resolver from the assembly lifecycle', () {
      final assembly = _TestNotifier();
      addTearDown(assembly.dispose);
      var revision = 1;
      final resolver = ComicSourceSemanticResolver(
        resolverSource(key: 'resolver_lifecycle_dispose'),
        assemblyLifecycle: assembly,
        assemblyRevision: () => revision,
      );

      var notifications = 0;
      resolver.lifecycle.addListener(() => notifications++);
      resolver.dispose();

      revision = 2;
      assembly.notify();
      expect(notifications, 0);
    });
  });

  group('lane release delegation', () {
    test('releaseLane forwards to the capability once', () async {
      final released = <SemanticSearchRequestScope>[];
      final resolver = ComicSourceSemanticResolver(
        resolverSource(
          key: 'resolver_release',
          semantic: SemanticSearchData(
            (value, options, page, {required requestScope}) async =>
                const Res(<Comic>[]),
            null,
            releaseLane: (scope) async => released.add(scope),
          ),
        ),
      );
      addTearDown(resolver.dispose);

      final scope = SemanticSearchRequestScope();
      await resolver.releaseLane(scope);
      expect(released, hasLength(1));
      expect(identical(released.single, scope), isTrue);
    });

    test('releaseLane is a safe no-op without a capability', () async {
      final resolver = ComicSourceSemanticResolver(
        resolverSource(key: 'resolver_release_none'),
      );
      addTearDown(resolver.dispose);
      await resolver.releaseLane(SemanticSearchRequestScope());
    });
  });
}

/// `ChangeNotifier.notifyListeners` is protected, so a test needs its own
/// subclass to drive the source assembly lifecycle.
class _TestNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
