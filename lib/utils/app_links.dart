import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

void handleLinks() {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri);
  });
}

Future<bool> handleAppLink(
  Uri uri, {
  void Function(String message)? onDisabledSource,
}) async {
  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if (id != null) {
          if (!isSourceEnabled(source.key)) {
            final message = 'Enable this comic source in settings first.'.tl;
            if (onDisabledSource != null) {
              onDisabledSource(message);
            } else {
              App.rootContext.showMessage(message: message);
            }
            return true;
          }
          if (App.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          App.mainNavigatorKey!.currentContext?.to(() {
            return ComicPage(id: id, sourceKey: source.key);
          });
          return true;
        }
        return false;
      }
    }
  }
  return false;
}
