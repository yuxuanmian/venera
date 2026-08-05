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
        _SliderSetting(
          title: "Follow Update Threads".tl,
          settingsIndex: 'followUpdateThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
        _SliderSetting(
          title: "Follow Update Batch Delay (seconds)".tl,
          settingsIndex: 'followUpdateBatchDelay',
          interval: 0.5,
          min: 0,
          max: 5,
        ).toSliver(),
      ],
    );
  }
}
