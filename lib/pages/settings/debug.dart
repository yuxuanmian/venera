part of 'settings_page.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => DebugPageState();
}

class DebugPageState extends State<DebugPage> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Debug".tl)),
        // Developer mode: the global gate for per-comic debug info. Kept at
        // the top of this page with a highlighted card so it is easy to find.
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            decoration: BoxDecoration(
              color: context.colorScheme.primaryContainer.withValues(
                alpha: 0.35,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: context.colorScheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: SwitchListTile(
              title: Row(
                children: [
                  Icon(
                    Icons.developer_mode,
                    color: context.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Developer Mode".tl,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              subtitle: Text("Show debug info in comic details".tl),
              value: appdata.developerMode,
              onChanged: (value) {
                // Rebuild so the switch reflects the new value immediately;
                // without setState the thumb only moves on the next rebuild
                // (e.g. during the page-exit transition).
                setState(() {
                  appdata.settings['developerMode'] = value;
                });
                appdata.saveData();
              },
            ),
          ),
        ),
        _CallbackSetting(
          title: "Catalog Diagnostics".tl,
          actionTitle: "Open".tl,
          callback: () => context.to(() => const CatalogDiagnostics()),
        ).toSliver(),
        _CallbackSetting(
          title: "Open Log".tl,
          callback: () {
            context.to(() => const LogsPage());
          },
          actionTitle: 'Open'.tl,
        ).toSliver(),
        _SwitchSetting(
          title: "Ignore Certificate Errors".tl,
          settingKey: "ignoreBadCertificate",
        ).toSliver(),
      ],
    );
  }
}
