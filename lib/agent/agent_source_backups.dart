import 'dart:convert';
import 'dart:io';

import 'agent_models.dart';

/// A saved copy of a comic source's code.
class AgentSourceBackup {
  final String id;
  final String sourceKey;
  final DateTime createdAt;

  /// True for copies saved automatically before an edit or restore.
  final bool automatic;
  final String note;
  final int bytes;

  const AgentSourceBackup({
    required this.id,
    required this.sourceKey,
    required this.createdAt,
    required this.automatic,
    required this.note,
    required this.bytes,
  });

  AgentJson toJson() => {
    'backup_id': id,
    'source_key': sourceKey,
    'created_at': createdAt.toIso8601String(),
    'automatic': automatic,
    if (note.isNotEmpty) 'note': note,
    'bytes': bytes,
  };
}

/// Copies of source code the agent can restore after a bad edit. Each backup
/// is one JSON file, so listing and deleting need no index to stay in sync.
class AgentSourceBackups {
  final Directory directory;

  AgentSourceBackups(this.directory);

  File _file(String id) => File('${directory.path}/$id.json');

  static bool _validId(String id) => RegExp(r'^[\w-]{1,80}$').hasMatch(id);

  /// Newest first.
  Future<List<AgentSourceBackup>> list({String? sourceKey}) async {
    if (!await directory.exists()) return [];
    final backups = <AgentSourceBackup>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = agentObject(jsonDecode(await entity.readAsString()));
        final key = json['source_key'] as String;
        if (sourceKey != null && key != sourceKey) continue;
        backups.add(
          AgentSourceBackup(
            id: json['id'] as String,
            sourceKey: key,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              json['created_at'] as int,
            ),
            automatic: json['automatic'] == true,
            note: json['note'] as String? ?? '',
            bytes: utf8.encode(json['code'] as String).length,
          ),
        );
      } catch (_) {
        // Unreadable files are left alone; they are not offered for restore.
      }
    }
    backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return backups;
  }

  Future<AgentSourceBackup> create(
    String sourceKey,
    String code, {
    bool automatic = false,
    String note = '',

    /// Automatic copies kept for the source; older ones are removed. Manual
    /// copies are never removed here.
    int keep = 10,
  }) async {
    await directory.create(recursive: true);
    final now = DateTime.now();
    final id = '${now.millisecondsSinceEpoch}-${agentId().substring(0, 8)}';
    await _file(id).writeAsString(
      jsonEncode({
        'id': id,
        'source_key': sourceKey,
        'created_at': now.millisecondsSinceEpoch,
        'automatic': automatic,
        'note': note,
        'code': code,
      }),
      flush: true,
    );
    if (automatic) {
      final old = (await list(
        sourceKey: sourceKey,
      )).where((b) => b.automatic).skip(keep);
      for (final backup in old) {
        await delete(backup.id);
      }
    }
    return AgentSourceBackup(
      id: id,
      sourceKey: sourceKey,
      createdAt: now,
      automatic: automatic,
      note: note,
      bytes: utf8.encode(code).length,
    );
  }

  /// The source key and code of a backup, or null when it does not exist.
  Future<(String, String)?> read(String id) async {
    if (!_validId(id)) return null;
    final file = _file(id);
    if (!await file.exists()) return null;
    final json = agentObject(jsonDecode(await file.readAsString()));
    return (json['source_key'] as String, json['code'] as String);
  }

  /// Returns whether a backup was removed.
  Future<bool> delete(String id) async {
    if (!_validId(id)) return false;
    final file = _file(id);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }
}
