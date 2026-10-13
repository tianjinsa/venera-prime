import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/follow_updates.dart';

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  String? get folder => appdata.settings["followUpdatesFolder"];

  void getCount() {
    if (folder == null) {
      _count = 0;
      return;
    }
    if (!LocalFavoritesManager().folderNames.contains(folder)) {
      _count = 0;
      appdata.settings["followUpdatesFolder"] = null;
      Future.microtask(() {
        appdata.saveData();
      });
    } else {
      _count = LocalFavoritesManager().countUpdates(folder!);
    }
  }

  void updateCount() {
    setState(() {
      getCount();
    });
  }

  @override
  void initState() {
    super.initState();
    getCount();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => FollowUpdatesPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Follow Updates'.tl, style: ts.s18)),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (_count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 16, left: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Text(
                    '@c updates'.tlParams({'c': _count}),
                    style: ts.s16,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  static const _checkIntervalOptions = [1, 6, 12, 24, 48, 72, 168];

  String? get folder => appdata.settings["followUpdatesFolder"];

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];

  int get checkIntervalHours {
    var value = appdata.settings["followUpdatesCheckIntervalHours"];
    if (value is num && value >= 1) {
      return value.toInt();
    }
    return 24;
  }

  bool get checkOnStart =>
      appdata.settings["followUpdatesCheckOnStart"] != false;

  String get fixedCheckTime {
    var value = appdata.settings["followUpdatesCheckFixedTime"];
    return value is String ? value : "";
  }

  String formatCheckInterval(int hours) {
    if (hours == 1) {
      return "Every hour".tl;
    }
    return "Every @a hours".tlParams({"a": hours});
  }

  String get scheduleDescription {
    if (fixedCheckTime.isEmpty) {
      return "Automatic checks run at most once every @a hours.".tlParams({
        "a": checkIntervalHours,
      });
    }
    return "Automatic checks run after @time, at most once every @a hours."
        .tlParams({"time": fixedCheckTime, "a": checkIntervalHours});
  }

  TimeOfDay? parseFixedCheckTime() {
    var parts = fixedCheckTime.split(":");
    if (parts.length != 2) {
      return null;
    }
    var hour = int.tryParse(parts[0]);
    var minute = int.tryParse(parts[1]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return null;
    }
    return TimeOfDay(hour: hour, minute: minute);
  }

  String formatTimeOfDay(TimeOfDay time) {
    return "${time.hour.toString().padLeft(2, '0')}:"
        "${time.minute.toString().padLeft(2, '0')}";
  }

  Future<void> saveFollowUpdateSetting(String key, dynamic value) async {
    setState(() {
      appdata.settings[key] = value;
    });
    await appdata.saveData();
  }

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    DateTime? parseUpdateTime(String value) {
      var timestamp = value.split("|").first.trim();
      var parsed = DateTime.tryParse(timestamp);
      if (parsed != null) return parsed;

      // Some sources use non-padded ISO-like dates (for example
      // `2026-8-12`), which DateTime.tryParse intentionally rejects.
      var match = RegExp(
        r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
      ).firstMatch(timestamp);
      if (match == null) return null;
      var year = int.parse(match.group(1)!);
      var month = int.parse(match.group(2)!);
      var day = int.parse(match.group(3)!);
      var hour = int.tryParse(match.group(4) ?? '0') ?? 0;
      var minute = int.tryParse(match.group(5) ?? '0') ?? 0;
      var second = int.tryParse(match.group(6) ?? '0') ?? 0;
      if (month < 1 || month > 12 || day < 1 || day > 31) return null;
      return DateTime(year, month, day, hour, minute, second);
    }

    allComics.sort((a, b) {
      if (a.updateTime == null && b.updateTime == null) {
        return 0;
      } else if (a.updateTime == null) {
        return 1;
      } else if (b.updateTime == null) {
        return -1;
      }
      try {
        var aDate = parseUpdateTime(a.updateTime!);
        var bDate = parseUpdateTime(b.updateTime!);
        if (aDate != null && bDate != null) {
          var comparison = bDate.compareTo(aDate);
          if (comparison != 0) return comparison;
        }
        return b.updateTime!.compareTo(a.updateTime!);
      } catch (_) {
        return b.updateTime!.compareTo(a.updateTime!);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (folder != null) {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Follow Updates'.tl)),
          if (folder == null)
            buildNotConfigured(context)
          else
            buildConfigured(context),
          SliverPadding(padding: const EdgeInsets.only(top: 8)),
          buildUpdatedComics(),
          buildAllComics(),
        ],
      ),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not Configured".tl),
            ),
            Text(
              "Choose a folder to follow updates.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text("Choose Folder".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListenableBuilder(
              listenable: BackgroundTasks.instance,
              builder: (context, _) {
                final key = 'follow-updates:$folder';
                final task = BackgroundTasks.instance.latest(key);
                return ListTile(
                  key: const Key('follow-update-task-status'),
                  leading: Icon(
                    task?.status == BackgroundTaskStatus.failed
                        ? Icons.error_outline
                        : Icons.stars_outlined,
                  ),
                  title: Text(folder!),
                  subtitle: TaskStatusText(taskKey: key),
                  trailing: task == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: task == null
                      ? null
                      : () => showBackgroundTask(context, task),
                );
              },
            ),
            Text(
              "Automatic update checking enabled.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            Text(scheduleDescription, style: ts.s14).paddingHorizontal(16),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text("Check follow updates on startup".tl),
              subtitle: Text(
                "Run one check immediately after the app starts.".tl,
              ),
              value: checkOnStart,
              onChanged: (value) {
                saveFollowUpdateSetting("followUpdatesCheckOnStart", value);
              },
            ),
            ListTile(
              title: Text("Follow updates check interval".tl),
              subtitle: Text(
                "Automatic checks skip comics checked within this interval.".tl,
              ),
              trailing: Select(
                current: formatCheckInterval(checkIntervalHours),
                values: _checkIntervalOptions.map(formatCheckInterval).toList(),
                minWidth: 112,
                onTap: (index) {
                  saveFollowUpdateSetting(
                    "followUpdatesCheckIntervalHours",
                    _checkIntervalOptions[index],
                  );
                },
              ),
            ),
            ListTile(
              title: Text("Fixed check time".tl),
              subtitle: Text(
                fixedCheckTime.isEmpty
                    ? "Automatic checks can run at any time.".tl
                    : "Automatic checks wait until this time of day.".tl,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fixedCheckTime.isEmpty ? "Disabled".tl : fixedCheckTime,
                    style: ts.s14,
                  ),
                  const SizedBox(width: 4),
                  if (fixedCheckTime.isNotEmpty)
                    IconButton(
                      tooltip: "Disable".tl,
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        saveFollowUpdateSetting(
                          "followUpdatesCheckFixedTime",
                          "",
                        );
                      },
                    )
                  else
                    const Icon(Icons.schedule),
                ],
              ),
              onTap: showFixedCheckTimePicker,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text("Change Folder".tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text("Check Now".tl),
                ),
                const SizedBox(width: 16),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text("Updates".tl, style: ts.s18),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear_all),
                    onPressed: () {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () {
                          LocalFavoritesManager().markAllAsRead();
                          appdata.saveData();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              "Read a comic or swipe left to mark its latest chapters as read. Following stays enabled."
                  .tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(
            comics: updatedComics,
            filterBlockedComics: false,
            itemWrapper: (comic, child) {
              final item = comic as FavoriteItemWithUpdateInfo;
              final currentFolder = folder;
              return Dismissible(
                key: ValueKey<Object>((
                  currentFolder,
                  item.type.value,
                  item.id,
                )),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: AlignmentDirectional.centerEnd,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          'Mark latest as read'.tl,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.done_all),
                    ],
                  ),
                ),
                onDismissed: (_) {
                  if (folder != currentFolder) return;
                  // Acknowledge the current update only. Keep the favorite,
                  // chapter baseline and tracking configuration intact.
                  LocalFavoritesManager().markAsRead(item.id, item.type);
                  appdata.saveData();
                },
                child: child,
              );
            },
          )
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text("No updates found".tl, style: ts.s16)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text("All Comics".tl, style: ts.s18),
              ],
            ),
          ),
        ),
        SliverGridComics(comics: allComics, filterBlockedComics: false),
      ],
    );
  }

  void showSelector() {
    var folders = LocalFavoritesManager().folderNames;
    if (folders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    String? selectedFolder;
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Choose Folder".tl,
              content: Column(
                children: [
                  ListTile(
                    title: Text("Folder".tl),
                    trailing: Select(
                      minWidth: 120,
                      current: selectedFolder,
                      values: folders,
                      onTap: (i) {
                        setState(() {
                          selectedFolder = folders[i];
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (appdata.settings["followUpdatesFolder"] != null)
                  TextButton(
                    onPressed: () {
                      disable();
                      context.pop();
                    },
                    child: Text("Disable".tl),
                  ),
                FilledButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          context.pop();
                          setFolder(selectedFolder!);
                        },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void showFixedCheckTimePicker() async {
    var selected = await showTimePicker(
      context: App.rootContext,
      initialTime: parseFixedCheckTime() ?? TimeOfDay.now(),
    );
    if (selected == null) {
      return;
    }
    await saveFollowUpdateSetting(
      "followUpdatesCheckFixedTime",
      formatTimeOfDay(selected),
    );
  }

  void disable() {
    FollowUpdatesService.disable();
  }

  void setFolder(String folder) {
    final task = FollowUpdatesService.selectFolder(folder);
    unawaited(showBackgroundTask(context, task));
  }

  void checkNow() {
    final selected = folder;
    if (selected == null) return;
    final existing = BackgroundTasks.instance.latest(
      'follow-updates:$selected',
    );
    final task = existing?.isRunning == true
        ? existing!
        : FollowUpdatesService.checkFolder(selected);
    unawaited(showBackgroundTask(context, task));
  }

  void updateComics() {
    if (folder == null) {
      setState(() {
        allComics = [];
        updatedComics = [];
      });
      return;
    }
    setState(() {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    });
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking updates
abstract class FollowUpdatesService {
  static BackgroundTask? _folderSelection;
  static int _selectionGeneration = 0;

  /// The service retains the subscription after the initiating page is closed.
  static BackgroundTask checkFolder(String folder) {
    _cancelChecking?.call();
    return _startFolderCheck(folder);
  }

  static BackgroundTask selectFolder(String folder) {
    _folderSelection?.requestCancel();
    final generation = ++_selectionGeneration;
    final previousFolder = appdata.settings['followUpdatesFolder'];
    var committed = false;
    Future<void>? rollback;
    _cancelChecking?.call();
    LocalFavoritesManager().prepareTableForFollowUpdates(folder, false);
    final task = _startFolderCheck(
      folder,
      markNewUpdates: false,
      shouldCancel: () => generation != _selectionGeneration,
      onCancel: () {
        // A cancellation during the final settings write must not leave the
        // newly selected folder committed. saveData serializes these writes.
        if (committed &&
            generation == _selectionGeneration &&
            appdata.settings['followUpdatesFolder'] == folder) {
          appdata.settings['followUpdatesFolder'] = previousFolder;
          rollback = appdata.saveData();
          updateFollowUpdatesUI();
        }
      },
      onComplete: () async {
        if (generation != _selectionGeneration ||
            !LocalFavoritesManager().folderNames.contains(folder)) {
          return;
        }
        committed = true;
        appdata.settings['followUpdatesFolder'] = folder;
        try {
          await appdata.saveData();
        } finally {
          await rollback;
        }
        updateFollowUpdatesUI();
      },
    );
    _folderSelection = task;
    return task;
  }

  static void disable() {
    _folderSelection?.requestCancel();
    _selectionGeneration++;
    _cancelChecking?.call();
    final folder = appdata.settings['followUpdatesFolder'];
    if (folder != null) {
      BackgroundTasks.instance
          .latest('follow-updates:$folder')
          ?.requestCancel();
    }
    appdata.settings['followUpdatesFolder'] = null;
    unawaited(appdata.saveData());
    updateFollowUpdatesUI();
  }

  static BackgroundTask _startFolderCheck(
    String folder, {
    bool markNewUpdates = true,
    bool Function()? shouldCancel,
    void Function()? onCancel,
    Future<void> Function()? onComplete,
  }) {
    final progress = updateFolder(
      folder,
      true,
      markNewUpdates: markNewUpdates,
      shouldCancel: shouldCancel,
      onCancel: onCancel,
      onComplete: onComplete,
    );
    final task = BackgroundTasks.instance.latest('follow-updates:$folder')!;
    task.resultLabel = 'View result';
    task.onOpenResult = () =>
        App.rootContext.to(() => const FollowUpdatesPage());
    unawaited(_consume(progress));
    return task;
  }

  static Future<void> _consume(Stream<UpdateProgress> progress) async {
    try {
      await for (final _ in progress) {}
    } catch (error, stack) {
      // The underlying checker retains the failure in the task center.
      Log.error('Check Updates', error, stack);
    } finally {
      updateFollowUpdatesUI();
    }
  }

  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  static bool _shouldCheckAfterFixedTime() {
    var fixedTimeValue = appdata.settings["followUpdatesCheckFixedTime"];
    var fixedTime = fixedTimeValue is String ? fixedTimeValue : "";
    if (fixedTime.isEmpty) {
      return true;
    }
    var parts = fixedTime.split(":");
    if (parts.length != 2) {
      return true;
    }
    var hour = int.tryParse(parts[0]);
    var minute = int.tryParse(parts[1]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return true;
    }
    var now = DateTime.now();
    var scheduled = DateTime(now.year, now.month, now.day, hour, minute);
    return !now.isBefore(scheduled);
  }

  static void _check() async {
    if (_isChecking) {
      return;
    }
    var folder = appdata.settings["followUpdatesFolder"];
    if (folder == null) {
      return;
    }
    bool isCanceled = false;
    _cancelChecking = () {
      isCanceled = true;
    };

    _isChecking = true;

    int updated = 0;
    try {
      while (DataSync().isDownloading) {
        if (isCanceled) return;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (isCanceled) return;
      await for (var progress in updateFolder(
        folder,
        false,
        shouldCancel: () => isCanceled,
        onCancel: () => isCanceled = true,
      )) {
        if (isCanceled) {
          return;
        }
        updated = progress.updated;
      }
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) {
        updateFollowUpdatesUI();
      }
    }
  }

  /// Initialize the checker.
  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    DataSync().addListener(updateFollowUpdatesUI);
    if (appdata.settings["followUpdatesCheckOnStart"] != false) {
      _check();
    }
    // A short interval will not affect the performance since every comic has a check time.
    Timer.periodic(const Duration(minutes: 10), (timer) {
      if (_shouldCheckAfterFixedTime()) {
        _check();
      }
    });
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
