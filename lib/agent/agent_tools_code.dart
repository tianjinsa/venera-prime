part of 'agent_tools.dart';

/// Logs and the code of installed comic sources, for fixing broken sources.
/// The agent edits existing sources only; it never creates one.
extension _AgentCodeTools on AgentTools {
  Future<Object?> _dispatchCode(
    String name,
    AgentJson a,
    AgentToolContext c,
  ) async => switch (name) {
    'app_logs' => _logs(a),
    'source_code_read' => _readCode(a, c),
    'source_code_grep' => _grepCode(a, c),
    'source_code_edit' => _editCode(a, c),
    'source_backups' => _backups(a),
    'source_backup_update' => _updateBackups(a, c),
    _ => _dispatchMore(name, a, c),
  };

  static const _logLevels = {
    'error': [LogLevel.error],
    'warning': [LogLevel.error, LogLevel.warning],
    'all': LogLevel.values,
  };

  /// Newest logs first, with repeats merged, so a launch with many identical
  /// failures still fits in a page. latest_id lets the agent read only the
  /// logs of a reproduction afterwards.
  AgentJson _logs(AgentJson a) {
    final levels = _logLevels[a['level'] ?? 'warning'];
    if (levels == null) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'level 需要 error、warning 或 all',
      );
    }
    final afterId = a['after_id'] ?? 0;
    if (afterId is! int || afterId < 0) {
      throw const AgentException('INVALID_ARGUMENT', 'after_id 需要非负整数');
    }
    final since = a.containsKey('since_minutes')
        ? DateTime.now().subtract(
            Duration(
              minutes: AgentTools._number(a, 'since_minutes', 60, 10080),
            ),
          )
        : null;
    final keyword = a.containsKey('keyword')
        ? AgentTools._text(a, 'keyword').toLowerCase()
        : null;
    final logs = app.logs();
    final groups = <String, List<LogItem>>{};
    for (final log in logs.reversed) {
      if (log.id <= afterId || !levels.contains(log.level)) continue;
      if (since != null && log.time.isBefore(since)) continue;
      if (keyword != null &&
          !log.title.toLowerCase().contains(keyword) &&
          !log.content.toLowerCase().contains(keyword)) {
        continue;
      }
      groups
          .putIfAbsent(
            '${log.level.name}\n${log.title}\n${log.content}',
            () => [],
          )
          .add(log);
    }
    const limit = 1500;
    return {
      ...AgentTools._paged(
        [
          for (final group in groups.values)
            {
              'id': group.first.id,
              'level': group.first.level.name,
              'title': group.first.title,
              'time': group.first.time.toIso8601String(),
              if (group.length > 1) ...{
                'repeats': group.length,
                'first_time': group.last.time.toIso8601String(),
              },
              'content': group.first.content.length > limit
                  ? '${group.first.content.substring(0, limit)}…'
                  : group.first.content,
              if (group.first.content.length > limit) 'truncated': true,
            },
        ],
        a,
        size: 20,
        maximum: 50,
      ),
      'latest_id': logs.lastOrNull?.id ?? afterId,
    };
  }

  Future<String> _code(ComicSource source) async =>
      (await app.readSourceCode(source)).replaceAll('\r\n', '\n');

  static String _fileName(ComicSource source) =>
      source.filePath.split(RegExp(r'[/\\]')).last;

  /// Very long lines, as in minified code, are shortened in listings.
  static String _line(int number, String text) =>
      '$number| ${text.length > 1000 ? '${text.substring(0, 1000)}…（此行共${text.length}字）' : text}';

  Future<AgentJson> _readCode(AgentJson a, AgentToolContext c) async {
    final reads = a['reads'];
    if (reads is! List ||
        reads.isEmpty ||
        reads.length > 5 ||
        reads.any((e) => e is! Map || e['source_key'] is! String)) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'reads 需要1到5个 {source_key, start_line, line_count}',
      );
    }
    var budget = 1000;
    final results = <AgentJson>[];
    for (final raw in reads) {
      c.run.check();
      final item = agentObject(raw);
      final key = item['source_key'] as String;
      try {
        final start = AgentTools._number(item, 'start_line', 1, 10000000);
        final count = AgentTools._number(item, 'line_count', 200, 500);
        final source = await _source(key, c);
        final lines = (await _code(source)).split('\n');
        final shown = math.min(count, budget);
        final end = math.min(lines.length, start - 1 + shown);
        budget -= math.max(0, end - start + 1);
        results.add({
          'source_key': key,
          'file_name': _fileName(source),
          'total_lines': lines.length,
          'start_line': start,
          'end_line': end,
          'content': [
            for (var i = start; i <= end; i++) _line(i, lines[i - 1]),
          ].join('\n'),
          if (end < lines.length) 'next_start_line': end + 1,
        });
      } on AgentException catch (e) {
        results.add({'source_key': key, ...e.toJson()});
      }
    }
    return {'results': results};
  }

  Future<AgentJson> _grepCode(AgentJson a, AgentToolContext c) async {
    final text = AgentTools._text(a, 'pattern');
    final regex = a['regex'] ?? false;
    final ignoreCase = a['ignore_case'] ?? true;
    if (regex is! bool || ignoreCase is! bool) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'regex 和 ignore_case 需要布尔值',
      );
    }
    final RegExp pattern;
    try {
      pattern = RegExp(
        regex ? text : RegExp.escape(text),
        caseSensitive: !ignoreCase,
      );
    } on FormatException {
      throw const AgentException('INVALID_ARGUMENT', 'pattern 不是有效的正则表达式');
    }
    final context = a.containsKey('context_lines')
        ? (a['context_lines'] is int &&
                  a['context_lines'] >= 0 &&
                  a['context_lines'] <= 5
              ? a['context_lines'] as int
              : throw const AgentException(
                  'INVALID_ARGUMENT',
                  'context_lines 应为0到5的整数',
                ))
        : 1;
    final keys = a['source_keys'];
    if (keys != null &&
        (keys is! List ||
            keys.isEmpty ||
            keys.length > 50 ||
            keys.any((e) => e is! String))) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'source_keys 需要1到50个源 key，省略则搜索全部源',
      );
    }
    await c.run.wait(initializeSources());
    final targets = keys == null
        ? sources()
        : [for (final key in keys) await _source(key as String, c)];
    final matches = <AgentJson>[];
    final counts = <String, int>{};
    for (final source in targets) {
      c.run.check();
      final String code;
      try {
        code = await _code(source);
      } catch (_) {
        continue;
      }
      final lines = code.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!pattern.hasMatch(lines[i])) continue;
        counts[source.key] = (counts[source.key] ?? 0) + 1;
        final from = math.max(0, i - context);
        final to = math.min(lines.length - 1, i + context);
        matches.add({
          'source_key': source.key,
          'line': i + 1,
          'content': [
            for (var j = from; j <= to; j++) _line(j + 1, lines[j]),
          ].join('\n'),
        });
      }
    }
    return {
      ...AgentTools._paged(matches, a, size: 30, maximum: 100),
      'matches_by_source': counts,
    };
  }

  /// Applies exact replacements in order. Nothing is written unless every
  /// edit matches and the new code parses as the same source; the previous
  /// code is kept as an automatic backup.
  Future<AgentJson> _editCode(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final edits = a['edits'];
    if (edits is! List ||
        edits.isEmpty ||
        edits.length > 20 ||
        edits.any(
          (e) =>
              e is! Map ||
              e['old_text'] is! String ||
              (e['old_text'] as String).isEmpty ||
              e['new_text'] is! String ||
              e['old_text'] == e['new_text'] ||
              (e.containsKey('replace_all') && e['replace_all'] is! bool),
        )) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'edits 需要1到20个 {old_text, new_text, replace_all}，old_text 非空且与 new_text 不同',
      );
    }
    final original = await _code(source);
    var code = original;
    final applied = <AgentJson>[];
    for (var i = 0; i < edits.length; i++) {
      final edit = agentObject(edits[i]);
      final old = (edit['old_text'] as String).replaceAll('\r\n', '\n');
      final replacement = (edit['new_text'] as String).replaceAll('\r\n', '\n');
      final count = old.allMatches(code).length;
      if (count == 0) {
        throw AgentException(
          'EDIT_NOT_FOUND',
          '第${i + 1}处修改的 old_text 在当前代码中不存在（按顺序应用前面的修改后），未写入任何修改；请用 source_code_read 或 source_code_grep 确认原文',
        );
      }
      if (count > 1 && edit['replace_all'] != true) {
        throw AgentException(
          'EDIT_AMBIGUOUS',
          '第${i + 1}处修改的 old_text 出现$count次，未写入任何修改；请加入更多上下文使其唯一，或设置 replace_all',
        );
      }
      final line = '\n'.allMatches(code.substring(0, code.indexOf(old))).length;
      code = code.replaceAll(old, replacement);
      applied.add({'replacements': count, 'line': line + 1});
    }
    c.run.check();
    final backups = app.sourceBackups;
    final backup = await backups.create(
      source.key,
      original,
      automatic: true,
      keep: store.settings.autoBackupLimit,
      note: '修改前自动备份',
    );
    try {
      await app.writeSourceCode(source, code);
    } catch (e) {
      await backups.delete(backup.id);
      final message = e.toString();
      throw AgentException(
        'PARSE_FAILED',
        '新代码无法作为该源加载，未写入：${message.length > 800 ? '${message.substring(0, 800)}…' : message}',
      );
    }
    return {
      'source_key': source.key,
      'status': 'saved',
      'edits': applied,
      'total_lines': '\n'.allMatches(code).length + 1,
      'backup_id': backup.id,
    };
  }

  Future<AgentJson> _backups(AgentJson a) async {
    final key = a.containsKey('source_key')
        ? AgentTools._text(a, 'source_key')
        : null;
    final backups = await app.sourceBackups.list(sourceKey: key);
    return {
      ...AgentTools._paged(
        backups.map((b) => b.toJson()).toList(),
        a,
        size: 20,
        maximum: 50,
      ),
      'total_bytes': backups.fold<int>(0, (sum, b) => sum + b.bytes),
    };
  }

  Future<AgentJson> _updateBackups(AgentJson a, AgentToolContext c) async {
    final create = a['create'] ?? const [];
    final restore = a['restore'] ?? const [];
    final delete = a['delete'] ?? const [];
    if (create is! List ||
        restore is! List ||
        delete is! List ||
        create.length + restore.length + delete.length == 0 ||
        create.length > 20 ||
        restore.length > 20 ||
        delete.length > 50 ||
        create.any((e) => e is! Map || e['source_key'] is! String) ||
        [...restore, ...delete].any((e) => e is! String || e.isEmpty)) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'create 需要最多20个 {source_key, note}，restore 最多20个、delete 最多50个备份 ID',
      );
    }
    final backups = app.sourceBackups;
    final results = <AgentJson>[];
    for (final raw in create) {
      c.run.check();
      final item = agentObject(raw);
      final key = item['source_key'] as String;
      final row = <String, dynamic>{'action': 'create', 'source_key': key};
      results.add(row);
      try {
        final source = await _source(key, c);
        final limit = store.settings.manualBackupLimit;
        if (limit > 0 &&
            (await backups.list(
                  sourceKey: key,
                )).where((b) => !b.automatic).length >=
                limit) {
          row.addAll({
            'status': 'failed',
            'reason': 'BACKUP_LIMIT',
            'message': '该源的手动备份已达上限$limit个，请先删除不再需要的备份',
          });
          continue;
        }
        final note = item['note'] is String ? item['note'] as String : '';
        final backup = await backups.create(
          key,
          await _code(source),
          note: note.length > 200 ? note.substring(0, 200) : note,
        );
        row.addAll({'status': 'created', 'backup_id': backup.id});
      } on AgentException catch (e) {
        row.addAll({'status': 'failed', 'reason': e.code});
      }
    }
    final restored = <String>{};
    for (final raw in restore) {
      c.run.check();
      final id = raw as String;
      final row = <String, dynamic>{'action': 'restore', 'backup_id': id};
      results.add(row);
      final saved = await backups.read(id);
      if (saved == null) {
        row.addAll({'status': 'failed', 'reason': 'NOT_FOUND'});
        continue;
      }
      final (key, code) = saved;
      row['source_key'] = key;
      if (!restored.add(key)) {
        row.addAll({'status': 'skipped', 'reason': 'SOURCE_ALREADY_RESTORED'});
        continue;
      }
      try {
        final source = await _source(key, c);
        final current = await _code(source);
        if (current == code) {
          row.addAll({'status': 'skipped', 'reason': 'UNCHANGED'});
          continue;
        }
        final before = await backups.create(
          key,
          current,
          automatic: true,
          keep: store.settings.autoBackupLimit,
          note: '还原 $id 前自动备份',
        );
        try {
          await app.writeSourceCode(source, code);
        } catch (_) {
          await backups.delete(before.id);
          row.addAll({'status': 'failed', 'reason': 'PARSE_FAILED'});
          continue;
        }
        row.addAll({'status': 'restored', 'previous_backup_id': before.id});
      } on AgentException catch (e) {
        row.addAll({'status': 'failed', 'reason': e.code});
      }
    }
    for (final raw in delete) {
      c.run.check();
      final id = raw as String;
      results.add({
        'action': 'delete',
        'backup_id': id,
        ...await backups.delete(id)
            ? {'status': 'deleted'}
            : {'status': 'skipped', 'reason': 'NOT_FOUND'},
      });
    }
    return {
      'results': results,
      'summary': _AgentCatalogTools._summary(results, {
        'created',
        'restored',
        'deleted',
      }),
    };
  }
}
