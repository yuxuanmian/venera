part of 'settings_page.dart';

class FavoriteSettings extends StatefulWidget {
  const FavoriteSettings({super.key});

  @override
  State<FavoriteSettings> createState() => _FavoriteSettingsState();
}

class _FavoriteSettingsState extends State<FavoriteSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        _SwitchSetting(
          title: "Auto close favorite panel after operation".tl,
          settingKey: "autoCloseFavoritePanel",
        ).toSliver(),
      ],
    );
  }
}
