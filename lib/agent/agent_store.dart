import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/utils/atomic_file.dart';
import 'agent_models.dart';
import 'agent_context.dart';

/// Entirely local storage, outside the app's existing backup manifest.
class AgentStore {
  final Directory directory;
  final Database _db;
  AgentSettings settings;
  Map<String, String> secrets;
  Future<void> _saving = Future.value();
  bool _closed = false;

  AgentStore._(this.directory, this._db, this.settings, this.secrets);

  static Future<AgentStore> open(String path) async {
    final directory = Directory(path);
    await directory.create(recursive: true);
    Future<AgentJson> read(String name) async {
      final file = File('$path/$name');
      if (!await file.exists()) return {};
      try {
        return agentObject(jsonDecode(await file.readAsString()));
      } catch (_) {
        throw FormatException('Agent 的 $name 无法读取，请检查文件，原数据已保留');
      }
    }

    final config = await read('config.json');
    final settings = AgentSettings.fromJson(config);
    for (final model in settings.models) {
      model.validate();
    }
    if (!['never', 'destructive', 'all'].contains(settings.confirmPolicy)) {
      throw const FormatException('无效的 Agent 确认策略');
    }
    final secrets = Map<String, String>.from(await read('secrets.json'));
    final db = sqlite3.open('$path/agent.db');
    try {
      final store = AgentStore._(directory, db, settings, secrets);
      store._initialize();
      return store;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  void _initialize() {
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('PRAGMA busy_timeout = 3000;');
    final version =
        _db.select('PRAGMA user_version;').first.values.first as int;
    if (version > 2) {
      throw const FormatException('Agent 数据来自更新版本，请更新应用后再打开');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, title TEXT NOT NULL,
        model_id TEXT, thinking_id TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        conversation TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL, parts TEXT NOT NULL, search_text TEXT NOT NULL,
        model_id TEXT, thinking_id TEXT, state TEXT NOT NULL,
        error TEXT, created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS comic_seen (
        conversation TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        source_key TEXT NOT NULL, comic_id TEXT NOT NULL, brief TEXT NOT NULL,
        PRIMARY KEY (conversation, source_key, comic_id)
      );
      CREATE TABLE IF NOT EXISTS showcases (
        id TEXT PRIMARY KEY,
        conversation TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        title TEXT NOT NULL, note TEXT NOT NULL, created_at INTEGER NOT NULL,
        dismissed INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS showcase_items (
        set_id TEXT NOT NULL REFERENCES showcases(id) ON DELETE CASCADE,
        source_key TEXT NOT NULL, comic_id TEXT NOT NULL, brief TEXT NOT NULL,
        seq INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (set_id, source_key, comic_id)
      );
      CREATE TABLE IF NOT EXISTS undo_records (
        id TEXT PRIMARY KEY,
        conversation TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        payload TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversation_context (
        conversation TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
        summary TEXT NOT NULL DEFAULT '', through_message_id TEXT,
        usage TEXT, usage_model_id TEXT, compacted_at INTEGER,
        compaction_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS showcase_operations (
        set_id TEXT PRIMARY KEY REFERENCES showcases(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, folder TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation, seq);
      CREATE INDEX IF NOT EXISTS showcases_conversation ON showcases(conversation, created_at);
    ''');
    _db.execute(
      "UPDATE messages SET state = 'interrupted' WHERE state = 'running';",
    );
    for (final row in _db.select(
      "SELECT id,parts FROM messages WHERE state='interrupted';",
    )) {
      final parts = (jsonDecode(row['parts'] as String) as List)
          .map(agentObject)
          .toList();
      var changed = false;
      for (final part in parts) {
        if (part['type'] == 'tool_call' &&
            ['running', 'pending'].contains(part['state'])) {
          part['state'] = 'interrupted';
          part['result'] ??= const AgentException(
            'CANCELLED',
            '应用退出时工具未完成，没有成功结果',
          ).toJson();
          changed = true;
        }
      }
      if (changed) {
        _db.execute('UPDATE messages SET parts=? WHERE id=?;', [
          jsonEncode(parts),
          row['id'],
        ]);
      }
    }
    if (version < 2) _backfillOperationShowcases();
    _db.execute('PRAGMA user_version = 2;');
  }

  void _backfillOperationShowcases() {
    // Existing conversations should gain the new collection groups too.
    // Replay only their display receipts, never their actual write tools.
    final rows = _db.select(
      "SELECT conversation,parts FROM messages WHERE role='assistant' ORDER BY seq;",
    );
    for (final row in rows) {
      final conversationId = row['conversation'] as String;
      for (final raw in jsonDecode(row['parts'] as String) as List) {
        final part = agentObject(raw);
        if (part['type'] != 'tool_call') continue;
        final name = part['name'];
        final result = part['result'];
        if (result is! Map || result['ok'] != true || result['data'] is! Map) {
          continue;
        }
        final receipts = result['data']['results'];
        if (receipts is! List) continue;
        final arguments = part['arguments'] is Map
            ? agentObject(part['arguments'])
            : <String, dynamic>{};
        for (final receipt in receipts.whereType<Map>()) {
          final source = receipt['source_key'];
          final comicId = receipt['comic_id'];
          if (source is! String || comicId is! String) continue;
          final status = receipt['status'];
          if (['fav_add', 'later_add', 'fav_move'].contains(name) &&
              (['added', 'moved'].contains(status) ||
                  receipt['reason'] == 'ALREADY_EXISTS')) {
            final comic = seen(conversationId, source, comicId);
            final folder = name == 'fav_move'
                ? arguments['to_folder']
                : arguments['folder'];
            if (comic != null && (name == 'later_add' || folder is String)) {
              recordOperationComics(
                conversationId,
                name == 'later_add' ? 'later' : 'favorites',
                [comic],
                folder: folder as String? ?? '',
              );
            }
          }
          if (name == 'fav_move' && status == 'moved') {
            removeOperationComic(
              conversationId,
              'favorites',
              source,
              comicId,
              folder: arguments['from_folder'] as String?,
            );
          }
          if (['fav_remove', 'later_remove'].contains(name) &&
              (status == 'removed' || receipt['reason'] == 'NOT_PRESENT')) {
            removeOperationComic(
              conversationId,
              name == 'later_remove' ? 'later' : 'favorites',
              source,
              comicId,
              folder: arguments['folder'] as String?,
            );
          }
        }
      }
    }
  }

  Future<void> saveSettings(AgentSettings value, Map<String, String> keys) {
    for (final model in value.models) {
      model.validate();
    }
    if (!['never', 'destructive', 'all'].contains(value.confirmPolicy) ||
        value.models.map((m) => m.id).toSet().length != value.models.length) {
      throw const FormatException('重复的模型 ID 或无效确认策略');
    }
    final next = _saving.then((_) async {
      // Keep old keys until the new config is durable, including on failure.
      final mergedKeys = {...secrets, ...keys};
      await atomicWriteString(
        File('${directory.path}/secrets.json'),
        jsonEncode(mergedKeys),
      );
      await atomicWriteString(
        File('${directory.path}/config.json'),
        jsonEncode(value.toJson()),
      );
      settings = value;
      secrets = mergedKeys;
    });
    _saving = next.catchError((Object _) {});
    return next;
  }

  AgentConversation createConversation({String? modelId, String? thinkingId}) {
    final now = agentNow();
    final conversation = AgentConversation(
      id: agentId(),
      modelId: modelId,
      thinkingId: thinkingId,
      createdAt: now,
      updatedAt: now,
    );
    saveConversation(conversation);
    return conversation;
  }

  void saveConversation(AgentConversation c) {
    _db.execute(
      '''
      INSERT INTO conversations(id,title,model_id,thinking_id,created_at,updated_at)
      VALUES (?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title,
        model_id=excluded.model_id, thinking_id=excluded.thinking_id,
        updated_at=excluded.updated_at;
    ''',
      [c.id, c.title, c.modelId, c.thinkingId, c.createdAt, c.updatedAt],
    );
  }

  List<AgentConversation> conversations([String keyword = '']) {
    final pattern = '%${keyword.trim()}%';
    return _db
        .select(
          '''
      SELECT c.*, (SELECT COUNT(*) FROM messages m WHERE m.conversation=c.id) AS count
      FROM conversations c
      WHERE c.title LIKE ? OR EXISTS(
        SELECT 1 FROM messages m WHERE m.conversation=c.id AND m.search_text LIKE ?
      )
      ORDER BY c.updated_at DESC, c.rowid DESC;
    ''',
          [pattern, pattern],
        )
        .map(
          (row) => AgentConversation(
            id: row['id'] as String,
            title: row['title'] as String,
            modelId: row['model_id'] as String?,
            thinkingId: row['thinking_id'] as String?,
            createdAt: row['created_at'] as int,
            updatedAt: row['updated_at'] as int,
            messageCount: row['count'] as int,
          ),
        )
        .toList();
  }

  void deleteConversation(String id) {
    _db.execute('DELETE FROM conversations WHERE id=?;', [id]);
  }

  void saveMessage(AgentMessage message) {
    _db.execute(
      '''
      INSERT INTO messages(id,conversation,role,parts,search_text,model_id,
        thinking_id,state,error,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET parts=excluded.parts,
        search_text=excluded.search_text, state=excluded.state, error=excluded.error;
    ''',
      [
        message.id,
        message.conversationId,
        message.role,
        jsonEncode(message.parts),
        message.text,
        message.modelId,
        message.thinkingId,
        message.state,
        message.error,
        message.createdAt,
      ],
    );
    _db.execute('UPDATE conversations SET updated_at=? WHERE id=?;', [
      agentNow(),
      message.conversationId,
    ]);
  }

  List<AgentMessage> messages(String conversationId) => _db
      .select('SELECT * FROM messages WHERE conversation=? ORDER BY seq;', [
        conversationId,
      ])
      .map(
        (row) => AgentMessage(
          id: row['id'] as String,
          conversationId: conversationId,
          role: row['role'] as String,
          parts: (jsonDecode(row['parts'] as String) as List)
              .map(agentObject)
              .toList(),
          modelId: row['model_id'] as String?,
          thinkingId: row['thinking_id'] as String?,
          state: row['state'] as String,
          error: row['error'] as String?,
          createdAt: row['created_at'] as int,
        ),
      )
      .toList();

  void truncateFrom(AgentMessage message, {bool include = true}) {
    invalidateContextFrom(message, include: include);
    final comparison = include ? '>=' : '>';
    _db.execute(
      '''
      DELETE FROM messages WHERE conversation=? AND seq $comparison
        (SELECT seq FROM messages WHERE id=? AND conversation=?);
    ''',
      [message.conversationId, message.id, message.conversationId],
    );
  }

  AgentConversationContext conversationContext(String conversationId) {
    final rows = _db.select(
      'SELECT * FROM conversation_context WHERE conversation=?;',
      [conversationId],
    );
    if (rows.isEmpty) return const AgentConversationContext();
    final row = rows.first;
    return AgentConversationContext(
      summary: row['summary'] as String,
      throughMessageId: row['through_message_id'] as String?,
      usage: row['usage'] == null
          ? null
          : AgentUsage.fromResponse(jsonDecode(row['usage'] as String)),
      usageModelId: row['usage_model_id'] as String?,
      compactedAt: row['compacted_at'] as int?,
      compactionCount: row['compaction_count'] as int,
    );
  }

  void saveContext(String conversationId, AgentConversationContext value) =>
      _db.execute(
        '''
    INSERT INTO conversation_context(conversation,summary,through_message_id,usage,usage_model_id,compacted_at,compaction_count)
    VALUES (?,?,?,?,?,?,?) ON CONFLICT(conversation) DO UPDATE SET
      summary=excluded.summary, through_message_id=excluded.through_message_id,
      usage=excluded.usage, usage_model_id=excluded.usage_model_id,
      compacted_at=excluded.compacted_at, compaction_count=excluded.compaction_count;
  ''',
        [
          conversationId,
          value.summary,
          value.throughMessageId,
          value.usage == null ? null : jsonEncode(value.usage!.toJson()),
          value.usageModelId,
          value.compactedAt,
          value.compactionCount,
        ],
      );

  /// An edited/retried message must not survive as stale facts in a summary.
  void invalidateContextFrom(AgentMessage message, {bool include = true}) {
    final comparison = include ? '>=' : '>';
    _db.execute(
      '''
      DELETE FROM conversation_context WHERE conversation=? AND through_message_id IN (
        SELECT id FROM messages WHERE conversation=? AND seq $comparison
          (SELECT seq FROM messages WHERE id=? AND conversation=?)
      );
    ''',
      [
        message.conversationId,
        message.conversationId,
        message.id,
        message.conversationId,
      ],
    );
    _db.execute(
      'UPDATE conversation_context SET usage=NULL, usage_model_id=NULL WHERE conversation=?;',
      [message.conversationId],
    );
  }

  void remember(String conversationId, AgentComic comic, {String? alias}) {
    _db.execute(
      '''
      INSERT INTO comic_seen(conversation,source_key,comic_id,brief)
      VALUES (?,?,?,?) ON CONFLICT(conversation,source_key,comic_id)
      DO UPDATE SET brief=excluded.brief;
    ''',
      [
        conversationId,
        comic.sourceKey,
        alias ?? comic.comicId,
        jsonEncode(comic.toJson()),
      ],
    );
  }

  AgentComic? seen(String conversationId, String sourceKey, String comicId) {
    final rows = _db.select(
      '''
      SELECT brief FROM comic_seen WHERE conversation=? AND source_key=? AND comic_id=?;
    ''',
      [conversationId, sourceKey, comicId],
    );
    if (rows.isEmpty) return null;
    return AgentComic.fromJson(
      agentObject(jsonDecode(rows.first['brief'] as String)),
    );
  }

  String addShowcase(
    String conversationId,
    List<AgentComic> comics, {
    required String title,
    String note = '',
    bool replace = false,
  }) {
    final id = agentId();
    _db.execute('BEGIN;');
    try {
      if (replace) {
        _db.execute(
          '''
          UPDATE showcases SET dismissed=1 WHERE id=(
            SELECT id FROM showcases WHERE conversation=? AND dismissed=0
              AND NOT EXISTS (SELECT 1 FROM showcase_operations o WHERE o.set_id=showcases.id)
            ORDER BY created_at DESC, rowid DESC LIMIT 1
          );
        ''',
          [conversationId],
        );
      }
      _db.execute(
        '''
        INSERT INTO showcases(id,conversation,title,note,created_at) VALUES (?,?,?,?,?);
      ''',
        [id, conversationId, title, note, agentNow()],
      );
      for (var i = 0; i < comics.length; i++) {
        final comic = comics[i];
        _db.execute(
          '''
          INSERT OR IGNORE INTO showcase_items(set_id,source_key,comic_id,brief,seq)
          VALUES (?,?,?,?,?);
        ''',
          [id, comic.sourceKey, comic.comicId, jsonEncode(comic.toJson()), i],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    return id;
  }

  List<AgentShowcase> showcases(String conversationId) {
    return _db
        .select(
          '''
      SELECT s.*, o.kind, o.folder FROM showcases s
      LEFT JOIN showcase_operations o ON o.set_id=s.id
      WHERE s.conversation=? AND s.dismissed=0
      ORDER BY s.created_at DESC, s.rowid DESC;
    ''',
          [conversationId],
        )
        .map((row) {
          final id = row['id'] as String;
          final comics = _db
              .select(
                '''
        SELECT brief FROM showcase_items WHERE set_id=? AND hidden=0 ORDER BY seq;
      ''',
                [id],
              )
              .map(
                (r) => AgentComic.fromJson(
                  agentObject(jsonDecode(r['brief'] as String)),
                ),
              )
              .toList();
          return AgentShowcase(
            id: id,
            title: row['title'] as String,
            note: row['note'] as String,
            createdAt: row['created_at'] as int,
            comics: comics,
            kind: row['kind'] as String? ?? 'discovery',
            folder: row['folder'] as String?,
          );
        })
        .where((group) => group.comics.isNotEmpty)
        .toList();
  }

  /// One persistent operation group per collection/folder in this conversation.
  /// Repeating an add updates the existing group instead of creating duplicates.
  String recordOperationComics(
    String conversationId,
    String kind,
    List<AgentComic> comics, {
    String folder = '',
  }) {
    final rows = _db.select(
      '''
      SELECT s.id,s.dismissed FROM showcases s JOIN showcase_operations o ON o.set_id=s.id
      WHERE s.conversation=? AND o.kind=? AND o.folder=? LIMIT 1;
    ''',
      [conversationId, kind, folder],
    );
    final id = rows.isEmpty ? agentId() : rows.first['id'] as String;
    _db.execute('BEGIN;');
    try {
      if (rows.isEmpty) {
        _db.execute(
          'INSERT INTO showcases(id,conversation,title,note,created_at) VALUES (?,?,?,?,?);',
          [
            id,
            conversationId,
            kind == 'favorites' ? folder : '稍后再看',
            '',
            agentNow(),
          ],
        );
        _db.execute(
          'INSERT INTO showcase_operations(set_id,kind,folder) VALUES (?,?,?);',
          [id, kind, folder],
        );
      } else {
        if (rows.first['dismissed'] == 1) {
          _db.execute('UPDATE showcase_items SET hidden=1 WHERE set_id=?;', [
            id,
          ]);
        }
        _db.execute('UPDATE showcases SET dismissed=0 WHERE id=?;', [id]);
      }
      var seq =
          _db.select(
                'SELECT COALESCE(MAX(seq),-1)+1 AS next FROM showcase_items WHERE set_id=?;',
                [id],
              ).first['next']
              as int;
      for (final comic in comics) {
        _db.execute(
          '''
          INSERT INTO showcase_items(set_id,source_key,comic_id,brief,seq) VALUES (?,?,?,?,?)
          ON CONFLICT(set_id,source_key,comic_id) DO UPDATE SET brief=excluded.brief, hidden=0;
        ''',
          [
            id,
            comic.sourceKey,
            comic.comicId,
            jsonEncode(comic.toJson()),
            seq++,
          ],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    return id;
  }

  void removeOperationComic(
    String conversationId,
    String kind,
    String sourceKey,
    String comicId, {
    String? folder,
  }) => _db.execute(
    '''
    UPDATE showcase_items SET hidden=1 WHERE source_key=? AND comic_id=? AND set_id IN (
      SELECT s.id FROM showcases s JOIN showcase_operations o ON o.set_id=s.id
      WHERE s.conversation=? AND o.kind=? ${folder == null ? '' : 'AND o.folder=?'}
    );
  ''',
    [sourceKey, comicId, conversationId, kind, if (folder != null) folder],
  );

  void hideComic(String setId, AgentComic comic) => _db.execute(
    '''
    UPDATE showcase_items SET hidden=1 WHERE set_id=? AND source_key=? AND comic_id=?;
  ''',
    [setId, comic.sourceKey, comic.comicId],
  );

  void hideShowcase(String id) =>
      _db.execute('UPDATE showcases SET dismissed=1 WHERE id=?;', [id]);

  void clearShowcases(String conversationId) => _db.execute(
    'UPDATE showcases SET dismissed=1 WHERE conversation=?;',
    [conversationId],
  );

  void saveUndo(String id, String conversationId, List<AgentJson> entries) =>
      _db.execute(
        '''
      INSERT INTO undo_records(id,conversation,payload) VALUES (?,?,?)
      ON CONFLICT(id) DO UPDATE SET payload=excluded.payload;
    ''',
        [id, conversationId, jsonEncode(entries)],
      );

  List<AgentJson> undoEntries(String id, String conversationId) {
    final rows = _db.select(
      'SELECT payload FROM undo_records WHERE id=? AND conversation=?;',
      [id, conversationId],
    );
    if (rows.isEmpty) return [];
    return (jsonDecode(rows.first['payload'] as String) as List)
        .map(agentObject)
        .toList();
  }

  bool hasUndo(String id, String conversationId) =>
      undoEntries(id, conversationId).isNotEmpty;

  void deleteUndo(String id) =>
      _db.execute('DELETE FROM undo_records WHERE id=?;', [id]);

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }
}
