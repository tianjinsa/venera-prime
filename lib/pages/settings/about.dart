part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text(
              "Venera Prime is a free and open-source app for comic reading."
                  .tl,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ).paddingHorizontal(24).toSliver(),
        ListenableBuilder(
          listenable: BackgroundTasks.instance,
          builder: (context, _) => ListTile(
            title: Text("Check for updates".tl),
            subtitle: const TaskStatusText(taskKey: 'app-update-check'),
            trailing: Button.filled(
              child: Text(
                BackgroundTasks.instance
                            .latest('app-update-check')
                            ?.isRunning ==
                        true
                    ? "Checking".tl
                    : "Check".tl,
              ),
              onPressed: () => checkUpdateUi(),
            ).fixHeight(32),
          ),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("GitHub"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/venera-app/venera-prime");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Telegram"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://t.me/venera_release");
          },
        ).toSliver(),
      ],
    );
  }
}

Future<LatestRelease?> checkUpdate() async {
  const url =
      "https://api.github.com/repos/venera-app/venera-prime/releases/latest";
  final res = await AppDio().get<Map<String, dynamic>>(
    url,
    options: Options(
      headers: {"Accept": "application/vnd.github+json", "cache-time": "no"},
      responseType: ResponseType.json,
    ),
  );
  if (res.statusCode != 200 || res.data == null) {
    throw StateError('Release request failed: ${res.statusCode}');
  }
  return LatestRelease.fromJson(res.data!);
}

Future<LatestRelease?> startAppUpdateCheck({
  Future<LatestRelease?> Function()? fetch,
}) => BackgroundTasks.instance.run<LatestRelease?>(
  'app-update-check',
  "Check for updates".tl,
  (task) async {
    final release = await (fetch ?? checkUpdate)();
    if (release == null) {
      throw const FormatException('Invalid release response');
    }
    if (isNewerAppVersion(release.version, App.version)) {
      task.update(message: '${release.title} (${release.version})');
      task.resultLabel = "View update".tl;
      task.onOpenResult = () => showAppUpdateDialog(release);
    } else {
      task.update(message: "No new version available".tl);
    }
    return release;
  },
);

bool _appUpdateDialogOpen = false;

Future<void> showAppUpdateDialog(LatestRelease release) async {
  if (_appUpdateDialogOpen) return;
  _appUpdateDialogOpen = true;
  try {
    await showDialog<void>(
      context: App.rootContext,
      builder: (_) => _AppUpdateDialog(release: release),
    );
  } finally {
    _appUpdateDialogOpen = false;
  }
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  final future = startAppUpdateCheck();
  if (showMessageIfNoUpdate) {
    // Closing/minimizing this dialog never cancels the owned job.
    unawaited(
      showBackgroundTask(
        App.rootContext,
        BackgroundTasks.instance.latest('app-update-check')!,
      ),
    );
  }
  try {
    final release = await future;
    // Preserve the startup new-release notification, while manual checks keep
    // their result in the task dialog/center even when the page is closed.
    if (!showMessageIfNoUpdate &&
        release != null &&
        isNewerAppVersion(release.version, App.version)) {
      if (delay) await Future<void>.delayed(const Duration(seconds: 2));
      showAppUpdateDialog(release);
    }
  } catch (error, stack) {
    Log.error('Check Update', error, stack);
  }
}
