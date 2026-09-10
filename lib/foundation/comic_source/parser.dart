part of 'comic_source.dart';

/// return true if ver1 > ver2
bool compareSemVer(String ver1, String ver2) {
  ver1 = ver1.replaceFirst("-", ".");
  ver2 = ver2.replaceFirst("-", ".");
  List<String> v1 = ver1.split('.');
  List<String> v2 = ver2.split('.');

  for (int i = 0; i < 3; i++) {
    int num1 = int.parse(v1[i]);
    int num2 = int.parse(v2[i]);

    if (num1 > num2) {
      return true;
    } else if (num1 < num2) {
      return false;
    }
  }

  var v14 = v1.elementAtOrNull(3);
  var v24 = v2.elementAtOrNull(3);

  if (v14 != v24) {
    if (v14 == null && v24 != "hotfix") {
      return true;
    } else if (v14 == null) {
      return false;
    }
    if (v24 == null) {
      if (v14 == "hotfix") {
        return true;
      }
      return false;
    }
    return v14.compareTo(v24) > 0;
  }

  return false;
}

class ComicSourceParseException implements Exception {
  final String message;

  ComicSourceParseException(this.message);

  @override
  String toString() {
    return message;
  }
}

class ComicSourceParser {
  ManagedSourceContext? _executionContext;
  dynamic _runCode(
    String code, [
    String? name,
    ManagedSourceContext? context,
  ]) => JsEngine().runCode(code, name, context ?? _executionContext);

  /// comic source key
  String? _key;
  String? _sourceKey;

  String? _name;
  static int _validationCounter = 0;

  /// Managed Catalog entry point. It validates the declared key before the
  /// result can be handed to a Runtime assembly and never schedules site
  /// initialization while the context is still preparing.
  Future<ComicSource> parseManaged(
    String js,
    String filePath, {
    required String expectedKey,
    required ManagedSourceContext context,
  }) async {
    context.requirePreparing();
    final source = await parse(
      js,
      filePath,
      register: false,
      allowExistingKey: true,
      loadData: true,
      scheduleInit: true,
      runtimeContext: context,
    );
    if (source.key != expectedKey) {
      throw ComicSourceParseException(
        'Catalog entry key mismatch: expected $expectedKey, got ${source.key}',
      );
    }
    return source;
  }

  Future<ComicSource> parse(
    String js,
    String filePath, {
    bool register = true,
    bool allowExistingKey = false,
    bool loadData = true,
    bool scheduleInit = true,
    ManagedSourceContext? runtimeContext,
  }) async {
    js = js.replaceAll("\r\n", "\n");
    managedRuntimeBridge.require(runtimeContext);
    return _parseWithAdmission(
      js,
      filePath,
      register: register,
      allowExistingKey: allowExistingKey,
      loadData: loadData,
      scheduleInit: scheduleInit,
      executionContext: runtimeContext,
    );
  }

  Future<ComicSource> _parseWithAdmission(
    String js,
    String filePath, {
    required bool register,
    required bool allowExistingKey,
    required bool loadData,
    required bool scheduleInit,
    void Function()? requireCandidateAdmission,
    ManagedSourceContext? executionContext,
  }) async {
    requireCandidateAdmission?.call();
    _executionContext = executionContext;
    var line1 = js
        .split('\n')
        .firstWhereOrNull((e) => e.trim().startsWith("class "));
    if (line1 == null ||
        !line1.startsWith("class ") ||
        !line1.contains("extends ComicSource")) {
      throw ComicSourceParseException("Invalid Content");
    }
    var className = line1.split("class")[1].split("extends ComicSource").first;
    className = className.trim();
    requireCandidateAdmission?.call();
    _runCode("""(() => { $js
        this['temp'] = new $className()
        return null
      }).call()
    """, className);
    _name =
        _runCode("this['temp'].name") ??
        (throw ComicSourceParseException('name is required'));
    var key =
        _runCode("this['temp'].key") ??
        (throw ComicSourceParseException('key is required'));
    _sourceKey = key;
    var version =
        _runCode("this['temp'].version") ??
        (throw ComicSourceParseException('version is required'));
    var minAppVersion = _runCode("this['temp'].minAppVersion");
    var url = _runCode("this['temp'].url");
    if (minAppVersion != null) {
      if (compareSemVer(minAppVersion, App.version.split('-').first)) {
        throw ComicSourceParseException(
          "minAppVersion @version is required".tlParams({
            "version": minAppVersion,
          }),
        );
      }
    }
    if (!allowExistingKey) {
      for (var source in ComicSource.all()) {
        if (source.key == key) {
          throw ComicSourceParseException("key($key) already exists");
        }
      }
    }
    // Validate the source-owned key before replacing it with the isolated
    // runtime alias used by non-registering candidate parses.  Otherwise a
    // malformed candidate could pass validation because only the safe alias
    // was checked.
    _key = key;
    _checkKeyValidation();
    final runtimeKey = register
        ? key
        : "__venera_parse_${_validationCounter++}";
    _key = runtimeKey;
    _checkKeyValidation();

    requireCandidateAdmission?.call();
    _runCode("""
      ComicSource.sources.$_key = this['temp'];
      null;
    """);
    try {
      var source = ComicSource(
        _name!,
        key,
        _loadAccountConfig(),
        _loadCategoryData(),
        _loadCategoryComicsData(),
        _loadFavoriteData(),
        _loadExploreData(),
        _loadSearchData(),
        _parseSettings(),
        _parseLoadComicFunc(),
        _parseThumbnailLoader(),
        _parseLoadComicPagesFunc(),
        _parseImageLoadingConfigFunc(),
        _parseThumbnailLoadingConfigFunc(),
        filePath,
        url ?? "",
        version ?? "1.0.0",
        _parseCommentsLoader(),
        _parseSendCommentFunc(),
        _parseChapterCommentsLoader(),
        _parseSendChapterCommentFunc(),
        _parseLikeFunc(),
        _parseVoteCommentFunc(),
        _parseLikeCommentFunc(),
        _parseIdMatch(),
        _parseTranslation(),
        _parseClickTagEvent(),
        _parseTagSuggestionSelectFunc(),
        _parseLinkHandler(),
        _getValue("search.enableTagsSuggestions") ?? false,
        _getValue("comic.enableTagsTranslate") ?? false,
        _parseStarRatingFunc(),
        _parseArchiveDownloader(),
        runtimeContext: executionContext,
        scan: _parseScanCapabilities(),
      );

      if (loadData) {
        await source.loadData(context: executionContext);
      }

      if (scheduleInit && _checkExists("init")) {
        void runInit() {
          try {
            requireCandidateAdmission?.call();
            if (executionContext != null) {
              managedRuntimeBridge.require(executionContext);
            }
          } catch (_) {
            return;
          }
          void run() {
            _runCode(
              "ComicSource.sources.$runtimeKey.init()",
              null,
              executionContext,
            );
          }

          run();
        }

        if (executionContext == null) {
          Future.delayed(const Duration(milliseconds: 50), runInit);
        } else {
          executionContext.addAfterPublish(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            managedRuntimeBridge.run(executionContext, runInit);
          });
        }
      }

      return source;
    } finally {
      if (!register) {
        if (executionContext == null) {
          _runCode("delete ComicSource.sources.$runtimeKey");
        }
      }
    }
  }

  /// Discovers the optional scan object without invoking any source method.
  /// The returned callbacks retain the parsed runtime alias and context, so
  /// replacing a published source with another instance of the same key cannot
  /// redirect an old callback.
  ScanCapabilities? _parseScanCapabilities() {
    final shape = _runCode('''
      (() => {
        const scan = ComicSource.sources.$_key?.scan;
        if (scan === undefined || scan === null) return {absent: true};
        if (typeof scan !== "object" || Array.isArray(scan)) {
          return {invalid: "scan must be an object"};
        }
        const describe = (name) => {
          if (!Object.prototype.hasOwnProperty.call(scan, name)) {
            return {present: false};
          }
          const value = scan[name];
          if (value === null || typeof value !== "object" || Array.isArray(value)) {
            return {invalid: name + " must be an object"};
          }
          if (!Object.prototype.hasOwnProperty.call(value, "load")) {
            return {present: true, hasLoad: false};
          }
          if (typeof value.load !== "function") {
            return {invalid: name + ".load must be a function"};
          }
          const owner = ComicSource.sources.$_key;
          const original = value.load;
          const active = [];
          const check = (current, depth) => {
            if (depth > 8) throw new Error("scan result is too deep");
            if (current === null || typeof current === "string" ||
                typeof current === "boolean") return;
            if (typeof current === "number") {
              if (!Number.isFinite(current)) throw new Error("scan result is not finite");
              return;
            }
            if (typeof current === "undefined" || typeof current === "function" ||
                typeof current === "bigint" || current instanceof Date ||
                typeof current !== "object") {
              throw new Error("scan result is not JSON-safe");
            }
            if (active.includes(current)) throw new Error("scan result is cyclic");
            active.push(current);
            if (Array.isArray(current)) {
              current.forEach((item) => check(item, depth + 1));
            } else {
              const prototype = Object.getPrototypeOf(current);
              if (prototype !== Object.prototype && prototype !== null) {
                throw new Error("scan result is not a plain object");
              }
              Object.keys(current).forEach((key) => check(current[key], depth + 1));
            }
            active.pop();
          };
          const wrapped = async function(...args) {
            try {
              const callArgs = [...args];
              // flutter_qjs encodes a Dart null argument as JS undefined.
              // Collection's first cursor is an explicit protocol null, so
              // restore that value before the source state machine sees it.
              if (name === "collection" && typeof callArgs[1] === "undefined") {
                callArgs[1] = null;
              }
              const hostRequest = callArgs[callArgs.length - 1];
              if (typeof hostRequest === "function") {
                callArgs[callArgs.length - 1] = async (...requestArgs) => {
                  const envelope = await hostRequest(...requestArgs);
                  if (envelope && envelope.ok === true &&
                      envelope.response && typeof envelope.response === "object") {
                    return envelope.response;
                  }
                  if (envelope && envelope.ok === false &&
                      envelope.failure && typeof envelope.failure === "object") {
                    const failure = new Error("scan request failed");
                    failure.scanFailure = envelope.failure;
                    throw failure;
                  }
                  throw new Error("invalid scan host response envelope");
                };
              }
              const result = await original.apply(owner, callArgs);
              check(result, 0);
              let isCollectionFailure = false;
              if (name === "collection") {
                const hasFailure = result !== null &&
                    typeof result === "object" &&
                    !Array.isArray(result) &&
                    Object.prototype.hasOwnProperty.call(result, "failure");
                if (hasFailure) {
                  isCollectionFailure = true;
                  const keys = Object.keys(result);
                  const failure = result.failure;
                  const prototype = failure === null ||
                      typeof failure !== "object"
                      ? undefined
                      : Object.getPrototypeOf(failure);
                  if (keys.includes("items") || keys.includes("next") ||
                      failure === null || typeof failure !== "object" ||
                      Array.isArray(failure) ||
                      (prototype !== Object.prototype && prototype !== null)) {
                    throw new Error("invalid collection failure envelope");
                  }
                } else if (result === null ||
                    typeof result !== "object" ||
                    !Object.prototype.hasOwnProperty.call(result, "next") ||
                    typeof result.next === "undefined") {
                  throw new Error("collection result must own next");
                }
              }
              const encoded = JSON.stringify(result);
              if (typeof encoded !== "string" || encoded.length > 2 * 1024 * 1024) {
                throw new Error("scan result is too large");
              }
              if (name === "collection" && !isCollectionFailure &&
                  result.next !== null) {
                const cursor = JSON.stringify(result.next);
                if (typeof cursor !== "string" || cursor.length > 8192) {
                  throw new Error("scan cursor is too large");
                }
              }
              return result;
            } catch (error) {
              if (error && error.scanFailure && typeof error.scanFailure === "object") {
                return {failure: error.scanFailure};
              }
              throw error;
            }
          };
          return {present: true, hasLoad: true, load: wrapped};
        };
        return {
          comic: describe("comic"),
          collection: describe("collection"),
          primary: Object.prototype.hasOwnProperty.call(scan, "primary")
            ? scan.primary : null,
        };
      })()
    ''');
    try {
      return _buildScanCapabilities(shape);
    } finally {
      // The bridge returns a Dart graph that still owns every JSRef it
      // contains. Release the graph after transferring the load function to
      // its explicit JSAutoFreeFunction owner.
      _freeScanJsRefs(shape);
    }
  }

  ScanCapabilities? _buildScanCapabilities(dynamic shape) {
    if (shape is! Map) {
      return const ScanCapabilities.invalid('invalid scan declaration');
    }
    if (shape['absent'] == true) {
      return null;
    }
    if (shape['invalid'] is String) {
      return ScanCapabilities.invalid(shape['invalid'] as String);
    }
    final comic = shape['comic'];
    final collection = shape['collection'];
    if (comic is! Map || collection is! Map) {
      return const ScanCapabilities.invalid('invalid scan capability');
    }
    if (comic['invalid'] is String) {
      return ScanCapabilities.invalid(comic['invalid'] as String);
    }
    if (collection['invalid'] is String) {
      return ScanCapabilities.invalid(collection['invalid'] as String);
    }

    final comicLoad = comic['hasLoad'] == true ? comic['load'] : null;
    final collectionLoad = collection['hasLoad'] == true
        ? collection['load']
        : null;
    if (comic['present'] == true &&
        comic['hasLoad'] != true &&
        comicLoad == null) {
      return const ScanCapabilities.invalid('comic.load is required');
    }
    if (collection['present'] == true &&
        collection['hasLoad'] != true &&
        collectionLoad == null) {
      return const ScanCapabilities.invalid('collection.load is required');
    }
    final hasComic = comicLoad is JSInvokable;
    final hasCollection = collectionLoad is JSInvokable;
    final count = (hasComic ? 1 : 0) + (hasCollection ? 1 : 0);
    if (count == 0) {
      return const ScanCapabilities.invalid('scan has no load function');
    }

    final rawPrimary = shape['primary'];
    ScanProducer? primary;
    if (rawPrimary != null) {
      primary = ScanProducerValue.parse(rawPrimary);
      if (primary == null) {
        return const ScanCapabilities.invalid('invalid scan.primary');
      }
    }
    if (count == 1) {
      final only = hasComic ? ScanProducer.comic : ScanProducer.collection;
      if (primary != null && primary != only) {
        return const ScanCapabilities.invalid(
          'scan.primary points to a missing capability',
        );
      }
      primary ??= only;
    } else if (primary == null) {
      return const ScanCapabilities.invalid('scan.primary is required');
    }

    ScanCapability? comicCapability;
    ScanCapability? collectionCapability;
    final ownedFunctions = <JSAutoFreeFunction>[];

    JSAutoFreeFunction ownFunction(JSInvokable function) {
      for (final owned in ownedFunctions) {
        if (identical(owned.func, function)) return owned;
      }
      final owned = JSAutoFreeFunction(function);
      ownedFunctions.add(owned);
      return owned;
    }

    // The native bridge may expose closure values which are not part of the
    // public scan shape but are still present in the returned Dart graph.
    // Transfer all of them to explicit owners before releasing that graph.
    for (final function in _scanJsFunctions(shape)) {
      ownFunction(function);
    }

    if (hasComic) {
      final function = ownFunction(comicLoad);
      comicCapability = ScanCapability.comic(_wrapScanComicLoader(function));
    }
    if (hasCollection) {
      final function = ownFunction(collectionLoad);
      collectionCapability = ScanCapability.collection(
        _wrapScanCollectionLoader(function),
      );
    }
    void disposeFunctions() {
      for (final function in ownedFunctions) {
        function.dispose();
      }
    }

    _executionContext?.onRevoke(disposeFunctions);
    final capabilities = ScanCapabilities.supported(
      primary: primary,
      comic: comicCapability,
      collection: collectionCapability,
      onDispose: disposeFunctions,
    );
    JsEngine().registerScanCapabilities(capabilities);
    return capabilities;
  }

  List<JSInvokable> _scanJsFunctions(dynamic value) {
    final functions = <JSInvokable>[];
    final visited = Set<Object>.identity();
    void visit(dynamic current) {
      if (current is JSInvokable) {
        if (!functions.any((function) => identical(function, current))) {
          functions.add(current);
        }
        return;
      }
      if (current is List) {
        if (!visited.add(current)) return;
        for (final item in current) {
          visit(item);
        }
        return;
      }
      if (current is Map) {
        if (!visited.add(current)) return;
        for (final item in current.values) {
          visit(item);
        }
      }
    }

    visit(value);
    return functions;
  }

  void _freeScanJsRefs(dynamic value) {
    final visited = Set<Object>.identity();
    void visit(dynamic current) {
      if (current is JSRef) {
        if (visited.add(current)) current.free();
        return;
      }
      if (current is List) {
        if (!visited.add(current)) return;
        for (final item in current) {
          visit(item);
        }
        return;
      }
      if (current is Map) {
        if (!visited.add(current)) return;
        for (final item in current.values) {
          visit(item);
        }
      }
    }

    visit(value);
  }

  ScanComicLoader _wrapScanComicLoader(JSAutoFreeFunction function) {
    return (comicId, request) async {
      final value = function([comicId, request]);
      final result = value is Future ? await value : value;
      return _checkScanJsValue(result, collection: false);
    };
  }

  ScanCollectionLoader _wrapScanCollectionLoader(JSAutoFreeFunction function) {
    return (collectionKey, cursor, request) async {
      final value = function([collectionKey, cursor, request]);
      final result = value is Future ? await value : value;
      return _checkScanJsValue(result, collection: true);
    };
  }

  /// Dart-side safety check is deliberately repeated after the managed JS
  /// domain has wrapped the returned graph. The JS-side wrapper below is kept
  /// in the parser call path so an undefined collection `next` cannot be
  /// collapsed by the native bridge into null.
  dynamic _checkScanJsValue(dynamic value, {required bool collection}) {
    final active = Set<Object>.identity();
    void visit(dynamic current, int depth) {
      if (depth > 8) throw const FormatException('scan value is too deep');
      if (current == null || current is String || current is bool) return;
      if (current is num) {
        if (!current.isFinite) {
          throw const FormatException('scan value is not finite');
        }
        return;
      }
      if (current is Function ||
          current is JSInvokable ||
          current is DateTime) {
        throw const FormatException('scan value is not JSON-safe');
      }
      if (current is List) {
        if (!active.add(current)) {
          throw const FormatException('scan value is cyclic');
        }
        try {
          for (final item in current) {
            visit(item, depth + 1);
          }
        } finally {
          active.remove(current);
        }
        return;
      }
      if (current is Map) {
        if (!active.add(current)) {
          throw const FormatException('scan value is cyclic');
        }
        try {
          for (final entry in current.entries) {
            if (entry.key is! String) {
              throw const FormatException('scan value has a non-string key');
            }
            visit(entry.value, depth + 1);
          }
        } finally {
          active.remove(current);
        }
        return;
      }
      throw const FormatException('scan value is not JSON-safe');
    }

    visit(value, 0);
    if (collection && value is Map && value.containsKey('failure')) {
      if (value.containsKey('items') ||
          value.containsKey('next') ||
          value['failure'] is! Map) {
        throw const FormatException('invalid collection failure envelope');
      }
      return value;
    }
    if (collection && value is Map && !value.containsKey('next')) {
      throw const FormatException('collection result must contain next');
    }
    return value;
  }

  _checkKeyValidation() {
    // 仅允许数字和字母以及下划线
    if (!_key!.contains(RegExp(r"^[a-zA-Z0-9_]+$"))) {
      throw ComicSourceParseException("key $_key is invalid");
    }
  }

  bool _checkExists(String index) {
    // Existence checks must not bridge the value itself.  A function-valued
    // property would otherwise create a transient native JS handle that the
    // parser never owns, which becomes visible as a leak when a real source
    // is parsed and the engine is torn down.
    return _runCode("""
      (() => {
        try {
          const value = ComicSource.sources.$_key.$index;
          return value !== undefined && value !== null;
        } catch (_) {
          return false;
        }
      })()
    """) ==
        true;
  }

  dynamic _getValue(String index) {
    return _runCode("""
      (() => {
        try {
          const value = ComicSource.sources.$_key.$index;
          return value === undefined ? null : value;
        } catch (_) {
          return null;
        }
      })()
    """);
  }

  AccountConfig? _loadAccountConfig() {
    if (!_checkExists("account")) {
      return null;
    }

    Future<Res<bool>> Function(String account, String pwd)? login;

    if (_checkExists("account.login")) {
      login = (account, pwd) async {
        try {
          await _runCode("""
          ComicSource.sources.$_key.account.login(${jsonEncode(account)},
          ${jsonEncode(pwd)})
          """);
          var source = ComicSource.find(_sourceKey!)!;
          source.data["account"] = <String>[account, pwd];
          await source.saveData(runtimeContext: _executionContext);
          return const Res(true);
        } catch (e) {
          final failure = FailureSanitizer.fromException(e);
          Log.error("Network", failure.toJson().toString());
          return Res.error(failure.message ?? "Account login failed");
        }
      };
    }

    void logout() {
      _runCode("ComicSource.sources.$_key.account.logout()");
    }

    bool Function(String url, String title)? checkLoginStatus;

    void Function()? onLoginSuccess;

    if (_checkExists('account.loginWithWebview')) {
      checkLoginStatus = (url, title) {
        return _runCode("""
            ComicSource.sources.$_key.account.loginWithWebview.checkStatus(
              ${jsonEncode(url)}, ${jsonEncode(title)})
          """);
      };

      if (_checkExists('account.loginWithWebview.onLoginSuccess')) {
        onLoginSuccess = () {
          _runCode("""
            ComicSource.sources.$_key.account.loginWithWebview.onLoginSuccess()
          """);
        };
      }
    }

    Future<bool> Function(List<String>)? validateCookies;

    if (_checkExists('account.loginWithCookies?.validate')) {
      validateCookies = (cookies) async {
        try {
          var res = await _runCode("""
            ComicSource.sources.$_key.account.loginWithCookies.validate(${jsonEncode(cookies)})
          """);
          return res;
        } catch (e) {
          final failure = FailureSanitizer.fromException(e);
          Log.error("Network", failure.toJson().toString());
          return false;
        }
      };
    }

    return AccountConfig(
      login,
      _getValue("account.loginWithWebview?.url"),
      _getValue("account.registerWebsite"),
      logout,
      checkLoginStatus,
      onLoginSuccess,
      ListOrNull.from(_getValue("account.loginWithCookies?.fields")),
      validateCookies,
    );
  }

  List<ExplorePageData> _loadExploreData() {
    if (!_checkExists("explore")) {
      return const [];
    }
    var length = _runCode("ComicSource.sources.$_key.explore.length");
    var pages = <ExplorePageData>[];
    for (int i = 0; i < length; i++) {
      final String title = _getValue("explore[$i].title");
      final String type = _getValue("explore[$i].type");
      Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;
      Future<Res<List<Comic>>> Function(int page)? loadPage;
      Future<Res<List<Comic>>> Function(String? next)? loadNext;
      Future<Res<List<Object>>> Function(int index)? loadMixed;
      if (type == "singlePageWithMultiPart") {
        loadMultiPart = () async {
          try {
            var res = await _runCode(
              "ComicSource.sources.$_key.explore[$i].load()",
            );
            return Res(
              List.from(
                res.keys
                    .map(
                      (e) => ExplorePagePart(
                        e,
                        (res[e] as List)
                            .map<Comic>((e) => Comic.fromJson(e, _sourceKey!))
                            .toList(),
                        null,
                      ),
                    )
                    .toList(),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == "multiPageComicList") {
        if (_checkExists("explore[$i].load")) {
          loadPage = (int page) async {
            try {
              var res = await _runCode(
                "ComicSource.sources.$_key.explore[$i].load(${jsonEncode(page)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
                ),
                subData: res["maxPage"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        } else {
          loadNext = (next) async {
            try {
              var res = await _runCode(
                "ComicSource.sources.$_key.explore[$i].loadNext(${jsonEncode(next)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
                ),
                subData: res["next"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        }
      } else if (type == "multiPartPage") {
        loadMultiPart = () async {
          try {
            var res = await _runCode(
              "ComicSource.sources.$_key.explore[$i].load()",
            );
            return Res(
              List.from(
                (res as List).map((e) {
                  return ExplorePagePart(
                    e['title'],
                    (e['comics'] as List).map((e) {
                      return Comic.fromJson(e, _sourceKey!);
                    }).toList(),
                    PageJumpTarget.parse(_sourceKey!, e['viewMore']),
                  );
                }),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == 'mixed') {
        loadMixed = (index) async {
          try {
            var res = await _runCode(
              "ComicSource.sources.$_key.explore[$i].load(${jsonEncode(index)})",
            );
            var list = <Object>[];
            for (var data in (res['data'] as List)) {
              if (data is List) {
                list.add(
                  data.map((e) => Comic.fromJson(e, _sourceKey!)).toList(),
                );
              } else if (data is Map) {
                list.add(
                  ExplorePagePart(
                    data['title'],
                    (data['comics'] as List).map((e) {
                      return Comic.fromJson(e, _sourceKey!);
                    }).toList(),
                    data['viewMore'],
                  ),
                );
              }
            }
            return Res(list, subData: res['maxPage']);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      pages.add(
        ExplorePageData(
          title,
          switch (type) {
            "singlePageWithMultiPart" =>
              ExplorePageType.singlePageWithMultiPart,
            "multiPartPage" => ExplorePageType.singlePageWithMultiPart,
            "multiPageComicList" => ExplorePageType.multiPageComicList,
            "mixed" => ExplorePageType.mixed,
            _ => throw ComicSourceParseException(
              "Unknown explore page type $type",
            ),
          },
          loadPage,
          loadNext,
          loadMultiPart,
          loadMixed,
        ),
      );
    }
    return pages;
  }

  CategoryData? _loadCategoryData() {
    var doc = _getValue("category");

    if (doc?["title"] == null) {
      return null;
    }

    final String title = doc["title"];
    final bool? enableRankingPage = doc["enableRankingPage"];

    var categoryParts = <BaseCategoryPart>[];

    for (var c in doc["parts"]) {
      if (c["categories"] != null && c["categories"] is! List) {
        continue;
      }
      List? categories = c["categories"];
      if (categories == null || categories[0] is Map) {
        // new format
        final String name = c["name"];
        final String type = c["type"];
        final cs = categories
            ?.map(
              (e) => CategoryItem(
                e['label'],
                PageJumpTarget.parse(_sourceKey!, e['target']),
              ),
            )
            .toList();
        if (type != "dynamic" && (cs == null || cs.isEmpty)) {
          continue;
        }
        if (type == "fixed") {
          categoryParts.add(FixedCategoryPart(name, cs!));
        } else if (type == "random") {
          categoryParts.add(
            RandomCategoryPart(name, cs!, c["randomNumber"] ?? 1),
          );
        } else if (type == "dynamic" && categories == null) {
          var loader = c["loader"];
          if (loader is! JSInvokable) {
            throw "DynamicCategoryPart loader must be a function";
          }
          categoryParts.add(
            DynamicCategoryPart(name, JSAutoFreeFunction(loader), _sourceKey!),
          );
        }
      } else {
        // old format
        final String name = c["name"];
        final String type = c["type"];
        final List<String> tags = List.from(c["categories"]);
        final String itemType = c["itemType"];
        List<String>? categoryParams = ListOrNull.from(c["categoryParams"]);
        final String? groupParam = c["groupParam"];
        if (groupParam != null) {
          categoryParams = List.filled(tags.length, groupParam);
        }
        var cs = <CategoryItem>[];
        for (int i = 0; i < tags.length; i++) {
          PageJumpTarget target;
          if (itemType == 'category') {
            target = PageJumpTarget(_sourceKey!, 'category', {
              "category": tags[i],
              "param": categoryParams?.elementAtOrNull(i),
            });
          } else if (itemType == 'search') {
            target = PageJumpTarget(_sourceKey!, 'search', {
              "keyword": tags[i],
            });
          } else if (itemType == 'search_with_namespace') {
            target = PageJumpTarget(_sourceKey!, 'search', {
              "keyword": "$name:$tags[i]",
            });
          } else {
            target = PageJumpTarget(_sourceKey!, itemType, null);
          }
          cs.add(CategoryItem(tags[i], target));
        }
        if (type == "fixed") {
          categoryParts.add(FixedCategoryPart(name, cs));
        } else if (type == "random") {
          categoryParts.add(
            RandomCategoryPart(name, cs, c["randomNumber"] ?? 1),
          );
        }
      }
    }

    return CategoryData(
      title: title,
      categories: categoryParts,
      enableRankingPage: enableRankingPage ?? false,
      key: title,
    );
  }

  CategoryComicsData? _loadCategoryComicsData() {
    if (!_checkExists("categoryComics")) return null;

    List<CategoryComicsOptions>? options;
    if (_checkExists("categoryComics.optionList")) {
      options = <CategoryComicsOptions>[];
      for (var element in _getValue("categoryComics.optionList") ?? []) {
        LinkedHashMap<String, String> map = LinkedHashMap<String, String>();
        for (var option in element["options"]) {
          if (option.isEmpty || !option.contains("-")) {
            continue;
          }
          var split = option.split("-");
          var key = split.removeAt(0);
          var value = split.join("-");
          map[key] = value;
        }
        options.add(
          CategoryComicsOptions(
            element["label"] ?? "",
            map,
            List.from(element["notShowWhen"] ?? []),
            element["showWhen"] == null ? null : List.from(element["showWhen"]),
          ),
        );
      }
    }

    CategoryOptionsLoader? optionLoader;
    if (_checkExists("categoryComics.optionLoader")) {
      optionLoader = (category, param) async {
        try {
          dynamic res = _runCode("""
          ComicSource.sources.$_key.categoryComics.optionLoader(
            ${jsonEncode(category)}, ${jsonEncode(param)})
        """);
          if (res is Future) {
            res = await res;
          }
          if (res is! List) {
            return Res.error(
              "Invalid data:\nExpected: List\nGot: ${res.runtimeType}",
            );
          }
          var options = <CategoryComicsOptions>[];
          for (var element in res) {
            if (element is! Map) {
              return Res.error(
                "Invalid option data:\nExpected: Map\nGot: ${element.runtimeType}",
              );
            }
            LinkedHashMap<String, String> map = LinkedHashMap<String, String>();
            for (var option in element["options"] ?? []) {
              if (option.isEmpty || !option.contains("-")) {
                continue;
              }
              var split = option.split("-");
              var key = split.removeAt(0);
              var value = split.join("-");
              map[key] = value;
            }
            options.add(
              CategoryComicsOptions(
                element["label"] ?? "",
                map,
                List.from(element["notShowWhen"] ?? []),
                element["showWhen"] == null
                    ? null
                    : List.from(element["showWhen"]),
              ),
            );
          }
          return Res(options);
        } catch (e) {
          Log.error("Data Analysis", "Failed to load category options.\n$e");
          return Res.error(e.toString());
        }
      };
    }

    RankingData? rankingData;
    if (_checkExists("categoryComics.ranking")) {
      var options = <String, String>{};
      for (var option in _getValue("categoryComics.ranking.options")) {
        if (option.isEmpty || !option.contains("-")) {
          continue;
        }
        var split = option.split("-");
        var key = split.removeAt(0);
        var value = split.join("-");
        options[key] = value;
      }
      Future<Res<List<Comic>>> Function(String option, int page)? load;
      Future<Res<List<Comic>>> Function(String option, String? next)?
      loadWithNext;
      if (_checkExists("categoryComics.ranking.load")) {
        load = (option, page) async {
          try {
            var res = await _runCode("""
            ComicSource.sources.$_key.categoryComics.ranking.load(
              ${jsonEncode(option)}, ${jsonEncode(page)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
              ),
              subData: res["maxPage"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else {
        loadWithNext = (option, next) async {
          try {
            var res = await _runCode("""
            ComicSource.sources.$_key.categoryComics.ranking.loadWithNext(
              ${jsonEncode(option)}, ${jsonEncode(next)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
              ),
              subData: res["next"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      rankingData = RankingData(options, load, loadWithNext);
    }

    if (options == null && optionLoader == null) {
      options = [];
    }

    return CategoryComicsData(
      options: options,
      optionsLoader: optionLoader,
      load: (category, param, options, page) async {
        try {
          var res = await _runCode("""
              ComicSource.sources.$_key.categoryComics.load(
                ${jsonEncode(category)},
                ${jsonEncode(param)},
                ${jsonEncode(options)},
                ${jsonEncode(page)}
              )
            """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
            ),
            subData: res["maxPage"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      rankingData: rankingData,
    );
  }

  SearchPageData? _loadSearchData() {
    if (!_checkExists("search")) return null;
    var options = <SearchOptions>[];
    for (var element in _getValue("search.optionList") ?? []) {
      LinkedHashMap<String, String> map = LinkedHashMap<String, String>();
      for (var option in element["options"]) {
        if (option.isEmpty || !option.contains("-")) {
          continue;
        }
        var split = option.split("-");
        var key = split.removeAt(0);
        var value = split.join("-");
        map[key] = value;
      }
      options.add(
        SearchOptions(
          map,
          element["label"],
          element['type'] ?? 'select',
          element['default'] == null ? null : jsonEncode(element['default']),
        ),
      );
    }

    SearchFunction? loadPage;

    SearchNextFunction? loadNext;

    if (_checkExists('search.load')) {
      loadPage = (keyword, page, searchOption) async {
        try {
          var res = await _runCode("""
          ComicSource.sources.$_key.search.load(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
            ),
            subData: res["maxPage"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    } else {
      loadNext = (keyword, next, searchOption) async {
        try {
          var res = await _runCode("""
          ComicSource.sources.$_key.search.loadNext(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(next)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
            ),
            subData: res["next"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    return SearchPageData(options, loadPage, loadNext);
  }

  LoadComicFunc? _parseLoadComicFunc() {
    return (id) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.loadInfo(${jsonEncode(id)})
        """);
        if (res is! Map<String, dynamic>) throw "Invalid data";
        res['comicId'] = id;
        res['sourceKey'] = _sourceKey;
        return Res(ComicDetails.fromJson(res));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LoadComicPagesFunc? _parseLoadComicPagesFunc() {
    return (id, ep) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.loadEp(${jsonEncode(id)}, ${jsonEncode(ep)})
        """);
        return Res(List.from(res["images"]));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  FavoriteData? _loadFavoriteData() {
    if (!_checkExists("favorites")) return null;

    final bool multiFolder =
        _getValue("favorites.multiFolder") as bool? ?? false;
    final bool? singleFolderForSingleComic =
        _getValue("favorites.singleFolderForSingleComic") as bool?;

    Future<Res<T>> retryZone<T>(Future<Res<T>> Function() func) async {
      final source = ComicSource.find(_sourceKey!);
      if (source != null && !source.isLogged) {
        return const Res.error("Not login");
      }
      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        if (source == null) return res;
        var reLoginRes = await source.reLogin();
        if (!reLoginRes) {
          return const Res.error("Login expired and re-login failed");
        } else {
          return func();
        }
      }
      return res;
    }

    Future<Res<bool>> addOrDelFavFunc(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    ) async {
      func() async {
        try {
          await _runCode("""
            ComicSource.sources.$_key.favorites.addOrDelFavorite(
              ${jsonEncode(comicId)}, ${jsonEncode(folderId)}, ${jsonEncode(isAdding)}, ${jsonEncode(favId)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res<bool>.error(e.toString());
        }
      }

      return retryZone(func);
    }

    Future<Res<List<Comic>>> Function(int page, [String? folder])? loadComic;

    Future<Res<List<Comic>>> Function(String? next, [String? folder])? loadNext;

    if (_checkExists("favorites.loadComics")) {
      loadComic = (int page, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await _runCode("""
            ComicSource.sources.$_key.favorites.loadComics(
              ${jsonEncode(page)}, ${jsonEncode(folder)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
              ),
              subData: res["maxPage"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    if (_checkExists("favorites.loadNext")) {
      loadNext = (String? next, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await _runCode("""
            ComicSource.sources.$_key.favorites.loadNext(
              ${jsonEncode(next)}, ${jsonEncode(folder)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _sourceKey!),
              ),
              subData: res["next"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    FavoriteUpdateCheckData? updateCheck;
    final updateCheckValue = _getValue("favorites.updateCheck");
    if (updateCheckValue != null) {
      try {
        if (updateCheckValue is! Map) {
          throw ComicSourceParseException(
            "favorites.updateCheck must be an object",
          );
        }
        // markerScheme was part of the legacy source contract. It is accepted
        // as an input-only compatibility field, but never validated, negotiated,
        // prefixed, or used by the host.
        final markerScheme = updateCheckValue["markerScheme"] is String
            ? updateCheckValue["markerScheme"] as String
            : null;
        final rawInterval = updateCheckValue["scanInterval"];
        if (rawInterval is! int || rawInterval < 900 || rawInterval > 2592000) {
          throw ComicSourceParseException(
            "favorites.updateCheck.scanInterval is invalid",
          );
        }
        if (!_checkExists("favorites.updateCheck.load")) {
          throw ComicSourceParseException(
            "favorites.updateCheck.load is required",
          );
        }

        FavoriteUpdateSnapshot parseSnapshot(dynamic value) {
          if (value is! Map) {
            throw ComicSourceParseException(
              "favorites.updateCheck.load returned an invalid snapshot",
            );
          }
          final rawComics = value["comics"];
          final rawPageSize = value["pageSize"];
          final rawTotal = value["total"];
          if (rawComics is! List ||
              rawPageSize is! int ||
              rawPageSize < 1 ||
              rawPageSize > 200 ||
              rawTotal is! int ||
              rawTotal != rawComics.length) {
            throw ComicSourceParseException(
              "favorites.updateCheck.load returned an invalid snapshot shape",
            );
          }

          final ids = <String>{};
          final comics = <Comic>[];
          for (final rawComic in rawComics) {
            if (rawComic is! Map) {
              throw ComicSourceParseException(
                "favorites.updateCheck.load returned an invalid comic",
              );
            }
            final rawId = rawComic["id"];
            if (rawId is! String || rawId.trim().isEmpty || !ids.add(rawId)) {
              throw ComicSourceParseException(
                "favorites.updateCheck.load returned duplicate or empty comic IDs",
              );
            }
            final comic = Comic.fromJson(
              Map<String, dynamic>.from(rawComic),
              _sourceKey!,
            );
            final rawHint = rawComic["favoriteUpdate"];
            final rawUpdateTime = rawHint is Map ? rawHint["updateTime"] : null;
            if (rawHint is! Map ||
                (rawUpdateTime != null && rawUpdateTime is! String)) {
              throw ComicSourceParseException(
                "favorites.updateCheck.load returned a comic without full update evidence",
              );
            }
            final hint = comic.favoriteUpdate;
            if (hint == null ||
                hint.marker?.trim().isEmpty != false ||
                (hint.updateTime != null &&
                    (hint.updateTime!.trim().isEmpty ||
                        parseFollowUpdateActivityTime(
                              hint.updateTime,
                              now: DateTime.now(),
                            ) ==
                            null))) {
              throw ComicSourceParseException(
                "favorites.updateCheck.load returned a comic without full update evidence",
              );
            }
            comics.add(comic);
          }
          return FavoriteUpdateSnapshot(
            comics: comics,
            pageSize: rawPageSize,
            total: rawTotal,
          );
        }

        updateCheck = FavoriteUpdateCheckData(
          markerScheme: markerScheme,
          scanInterval: Duration(seconds: rawInterval),
          load: ([String? folderId]) async {
            Future<Res<FavoriteUpdateSnapshot>> func() async {
              try {
                final res = await _runCode("""
                  ComicSource.sources.$_key.favorites.updateCheck.load(
                    ${jsonEncode(folderId)})
                """);
                return Res(parseSnapshot(res));
              } catch (e, s) {
                Log.error("Network", "$e\n$s");
                return Res.error(e.toString());
              }
            }

            return retryZone(func);
          },
        );
      } finally {
        _freeScanJsRefs(updateCheckValue);
      }
    }

    Future<Res<Map<String, String>>> Function([String? comicId])? loadFolders;

    Future<Res<bool>> Function(String name)? addFolder;

    Future<Res<bool>> Function(String key)? deleteFolder;

    if (multiFolder) {
      loadFolders = ([String? comicId]) async {
        Future<Res<Map<String, String>>> func() async {
          try {
            var res = await _runCode("""
            ComicSource.sources.$_key.favorites.loadFolders(${jsonEncode(comicId)})
          """);
            List<String>? subData;
            if (res["favorited"] != null) {
              subData = List.from(res["favorited"]);
            }
            return Res(Map.from(res["folders"]), subData: subData);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
      if (_checkExists("favorites.addFolder")) {
        addFolder = (name) async {
          try {
            await _runCode("""
            ComicSource.sources.$_key.favorites.addFolder(${jsonEncode(name)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      if (_checkExists("favorites.deleteFolder")) {
        deleteFolder = (key) async {
          try {
            await _runCode("""
            ComicSource.sources.$_key.favorites.deleteFolder(${jsonEncode(key)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
    }

    return FavoriteData(
      key: _sourceKey!,
      title: _name!,
      multiFolder: multiFolder,
      loadComic: loadComic,
      loadNext: loadNext,
      loadFolders: loadFolders,
      addFolder: addFolder,
      deleteFolder: deleteFolder,
      addOrDelFavorite: addOrDelFavFunc,
      singleFolderForSingleComic: singleFolderForSingleComic ?? false,
      updateCheck: updateCheck,
    );
  }

  CommentsLoader? _parseCommentsLoader() {
    if (!_checkExists("comic.loadComments")) return null;
    return (id, subId, page, replyTo) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.loadComments(
            ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        return Res(
          (res["comments"] as List).map((e) => Comment.fromJson(e)).toList(),
          subData: res["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendCommentFunc? _parseSendCommentFunc() {
    if (!_checkExists("comic.sendComment")) return null;
    return (id, subId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await _runCode("""
            ComicSource.sources.$_key.comic.sendComment(
              ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var reLoginRes = await ComicSource.find(_sourceKey!)!.reLogin();
        if (!reLoginRes) {
          return const Res.error("Login expired and re-login failed");
        } else {
          return func();
        }
      }
      return res;
    };
  }

  ChapterCommentsLoader? _parseChapterCommentsLoader() {
    if (!_checkExists("comic.loadChapterComments")) return null;
    return (comicId, epId, page, replyTo) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.loadChapterComments(
            ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        return Res(
          (res["comments"] as List).map((e) => Comment.fromJson(e)).toList(),
          subData: res["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendChapterCommentFunc? _parseSendChapterCommentFunc() {
    if (!_checkExists("comic.sendChapterComment")) return null;
    return (comicId, epId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await _runCode("""
            ComicSource.sources.$_key.comic.sendChapterComment(
              ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var reLoginRes = await ComicSource.find(_sourceKey!)!.reLogin();
        if (!reLoginRes) {
          return const Res.error("Login expired and re-login failed");
        } else {
          return func();
        }
      }
      return res;
    };
  }

  GetImageLoadingConfigFunc? _parseImageLoadingConfigFunc() {
    if (!_checkExists("comic.onImageLoad")) {
      return null;
    }
    return (imageKey, comicId, ep) async {
      var res = _runCode("""
          ComicSource.sources.$_key.comic.onImageLoad(
            ${jsonEncode(imageKey)}, ${jsonEncode(comicId)}, ${jsonEncode(ep)})
        """);
      if (res is Future) {
        return await res;
      }
      return res;
    };
  }

  GetThumbnailLoadingConfigFunc? _parseThumbnailLoadingConfigFunc() {
    if (!_checkExists("comic.onThumbnailLoad")) {
      return null;
    }
    return (imageKey) {
      var res = _runCode("""
          ComicSource.sources.$_key.comic.onThumbnailLoad(${jsonEncode(imageKey)})
        """);
      if (res is! Map) {
        Log.error("Network", "function onThumbnailLoad return invalid data");
        throw "function onThumbnailLoad return invalid data";
      }
      return res as Map<String, dynamic>;
    };
  }

  ComicThumbnailLoader? _parseThumbnailLoader() {
    if (!_checkExists("comic.loadThumbnails")) {
      return null;
    }
    return (id, next) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.loadThumbnails(${jsonEncode(id)}, ${jsonEncode(next)})
        """);
        return Res(List<String>.from(res['thumbnails']), subData: res['next']);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeOrUnlikeComicFunc? _parseLikeFunc() {
    if (!_checkExists("comic.likeComic")) {
      return null;
    }
    return (id, isLiking) async {
      try {
        await _runCode("""
          ComicSource.sources.$_key.comic.likeComic(${jsonEncode(id)}, ${jsonEncode(isLiking)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  VoteCommentFunc? _parseVoteCommentFunc() {
    if (!_checkExists("comic.voteComment")) {
      return null;
    }
    return (id, subId, commentId, isUp, isCancel) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.voteComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isUp)}, ${jsonEncode(isCancel)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeCommentFunc? _parseLikeCommentFunc() {
    if (!_checkExists("comic.likeComment")) {
      return null;
    }
    return (id, subId, commentId, isLiking) async {
      try {
        var res = await _runCode("""
          ComicSource.sources.$_key.comic.likeComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isLiking)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  Map<String, Map<String, dynamic>> _parseSettings() {
    var value = _getValue("settings");
    if (value is Map) {
      var newMap = <String, Map<String, dynamic>>{};
      for (var e in value.entries) {
        if (e.key is! String) {
          continue;
        }
        var v = <String, dynamic>{};
        for (var e2 in e.value.entries) {
          if (e2.key is! String) {
            continue;
          }
          var v2 = e2.value;
          if (v2 is JSInvokable) {
            v2 = JSAutoFreeFunction(v2);
          }
          v[e2.key] = v2;
        }
        newMap[e.key] = v;
      }
      return newMap;
    }
    return {};
  }

  RegExp? _parseIdMatch() {
    if (!_checkExists("comic.idMatch")) {
      return null;
    }
    return RegExp(_getValue("comic.idMatch"));
  }

  Map<String, Map<String, String>>? _parseTranslation() {
    if (!_checkExists("translation")) {
      return null;
    }
    var data = _getValue("translation");
    var res = <String, Map<String, String>>{};
    for (var e in data.entries) {
      res[e.key] = Map<String, String>.from(e.value);
    }
    return res;
  }

  HandleClickTagEvent? _parseClickTagEvent() {
    if (!_checkExists("comic.onClickTag")) {
      return null;
    }
    return (namespace, tag) {
      var res = _runCode("""
          ComicSource.sources.$_key.comic.onClickTag(${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      if (res is! Map) {
        return null;
      }
      var r = Map<String, dynamic>.from(res);
      r.removeWhere((key, value) => value == null);
      return PageJumpTarget.parse(_sourceKey!, r);
    };
  }

  TagSuggestionSelectFunc? _parseTagSuggestionSelectFunc() {
    if (!_checkExists("search.onTagSuggestionSelected")) {
      return null;
    }
    return (namespace, tag) {
      var res = _runCode("""
          ComicSource.sources.$_key.search.onTagSuggestionSelected(
            ${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      return res is String ? res : "$namespace:$tag";
    };
  }

  LinkHandler? _parseLinkHandler() {
    if (!_checkExists("comic.link")) {
      return null;
    }
    List<String> domains = List.from(_getValue("comic.link.domains"));
    linkToId(String link) {
      var res = _runCode("""
          ComicSource.sources.$_key.comic.link.linkToId(${jsonEncode(link)})
        """);
      return res as String?;
    }

    return LinkHandler(domains, linkToId);
  }

  StarRatingFunc? _parseStarRatingFunc() {
    if (!_checkExists("comic.starRating")) {
      return null;
    }
    return (id, rating) async {
      try {
        await _runCode("""
          ComicSource.sources.$_key.comic.starRating(${jsonEncode(id)}, ${jsonEncode(rating)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  ArchiveDownloader? _parseArchiveDownloader() {
    if (!_checkExists("comic.archive")) {
      return null;
    }
    return ArchiveDownloader(
      (cid) async {
        try {
          var res = await _runCode("""
              ComicSource.sources.$_key.comic.archive.getArchives(${jsonEncode(cid)})
            """);
          return Res(
            (res as List).map((e) => ArchiveInfo.fromJson(e)).toList(),
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      (cid, aid) async {
        try {
          var res = await _runCode("""
              ComicSource.sources.$_key.comic.archive.getDownloadUrl(${jsonEncode(cid)}, ${jsonEncode(aid)})
            """);
          return Res(res as String);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
    );
  }
}
