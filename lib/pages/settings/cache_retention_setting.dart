import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

class CacheRetentionSetting extends StatelessWidget {
  const CacheRetentionSetting({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appdata.settings,
      builder: (context, _) {
        final stored = appdata.settings['cacheRetentionDays'];
        final days = stored is int && [0, 1, 3, 7, 30].contains(stored)
            ? stored
            : 7;
        return ListTile(
          title: Text('Keep unused cache'.tl),
          subtitle: Text(
            'Remove cached images after this many days without use. Opening an image restarts the timer. Downloaded and local comics are kept. Never disables age-based cleanup; the cache size limit still applies.'
                .tl,
          ),
          trailing: DropdownButton<int>(
            value: days,
            items: [
              for (final value in [1, 3, 7, 30, 0])
                DropdownMenuItem(
                  value: value,
                  child: Text(
                    value == 0
                        ? 'Never'.tl
                        : value == 1
                        ? '1 day'.tl
                        : '@days days'.tlParams({'days': value}),
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              appdata.settings['cacheRetentionDays'] = value;
              appdata.saveData();
            },
          ),
        );
      },
    );
  }
}
