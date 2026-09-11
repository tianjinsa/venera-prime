import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';

typedef AgentJson = Map<String, dynamic>;
const agentToolLabels = {
  'list_sources': '查看漫画源',
  'list_search_options': '读取搜索选项',
  'search_source': '搜索漫画',
  'comic_open_by_id': '按 ID 查看漫画',
  'comic_resolve': '识别漫画',
  'comic_get': '查看漫画详情',
  'showcase_comics': '展示漫画',
  'fav_list_folders': '查看收藏夹',
  'fav_list': '读取收藏',
  'fav_search': '搜索收藏',
  'fav_check': '检查收藏状态',
  'fav_add': '加入收藏',
  'fav_remove': '取消收藏',
  'fav_move': '移动收藏',
  'fav_create_folder': '创建收藏夹',
  'later_list': '读取稍后再看',
  'later_check': '检查稍后再看状态',
  'later_add': '加入稍后再看',
  'later_remove': '移出稍后再看',
};

String agentId() => const Uuid().v4();
int agentNow() => DateTime.now().millisecondsSinceEpoch;
AgentJson agentObject(Object? value) => value is Map
    ? Map<String, dynamic>.from(value)
    : throw const FormatException('需要 JSON 对象');

class AgentException implements Exception {
  final String code;
  final String message;
  const AgentException(this.code, this.message);
  AgentJson toJson() => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };
  @override
  String toString() => message;
}

/// Source requests cannot be aborted, but their late results must be ignored.
class AgentRun {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) {
      throw const AgentException('CANCELLED', '已停止等待');
    }
  }

  Future<T> wait<T>(
    Future<T> work, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    check();
    try {
      final result = await Future.any<T>([
        work,
        whenCancelled.then<T>(
          (_) => throw const AgentException('CANCELLED', '已停止等待'),
        ),
      ]).timeout(timeout);
      check();
      return result;
    } on TimeoutException {
      throw const AgentException('TIMEOUT', '请求超时，请稍后重试');
    }
  }
}

class AgentThinkingLevel {
  final String id;
  final String label;
  final AgentJson params;
  const AgentThinkingLevel({
    required this.id,
    required this.label,
    this.params = const {},
  });
  factory AgentThinkingLevel.fromJson(AgentJson json) => AgentThinkingLevel(
    id: json['id'] as String,
    label: json['label'] as String,
    params: agentObject(json['params'] ?? {}),
  );
  AgentJson toJson() => {'id': id, 'label': label, 'params': params};
}

class AgentModel {
  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final bool supportsVision;
  final bool includeReasoning;
  final bool stream;
  final List<AgentThinkingLevel> thinkingLevels;
  final String defaultThinking;
  final AgentJson extraBody;
  final Map<String, String> headers;
  final int contextWindowTokens;
  final double? temperature;
  const AgentModel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.supportsVision = false,
    this.includeReasoning = false,
    this.stream = true,
    this.thinkingLevels = const [
      AgentThinkingLevel(id: 'default', label: '默认'),
    ],
    this.defaultThinking = 'default',
    this.extraBody = const {},
    this.headers = const {},
    this.contextWindowTokens = 128000,
    this.temperature,
  });
  factory AgentModel.fromJson(AgentJson json) => AgentModel(
    id: json['id'] as String,
    name: json['name'] as String,
    baseUrl: json['base_url'] as String,
    model: json['model'] as String,
    supportsVision: json['supports_vision'] as bool? ?? false,
    includeReasoning: json['include_reasoning_in_context'] as bool? ?? false,
    stream: json['stream'] as bool? ?? true,
    thinkingLevels:
        (json['thinking_levels'] as List? ??
                [
                  {'id': 'default', 'label': '默认', 'params': {}},
                ])
            .map((e) => AgentThinkingLevel.fromJson(agentObject(e)))
            .toList(),
    defaultThinking: json['default_thinking'] as String? ?? 'default',
    extraBody: agentObject(json['extra_body'] ?? {}),
    headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
    contextWindowTokens: json['context_window_tokens'] as int? ?? 128000,
    temperature: (json['temperature'] as num?)?.toDouble(),
  );
  Uri get endpoint {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const FormatException('API 地址需要是有效的 HTTP(S) 地址，不含账号或查询参数');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '$path/chat/completions',
    );
  }

  void validate() {
    endpoint;
    if (id.isEmpty || name.trim().isEmpty || model.trim().isEmpty) {
      throw const FormatException('请填写显示名称和模型 ID');
    }
    if (contextWindowTokens < 1) {
      throw const FormatException('模型上下文容量需要是正整数');
    }
    if (thinkingLevels.isEmpty ||
        thinkingLevels.any((e) => e.id.isEmpty || e.label.trim().isEmpty) ||
        thinkingLevels.map((e) => e.id).toSet().length !=
            thinkingLevels.length ||
        !thinkingLevels.any((e) => e.id == defaultThinking)) {
      throw const FormatException('思考深度需要唯一 ID、显示名称以及有效的默认值');
    }
    if (headers.entries.any(
      (e) =>
          e.key.trim().isEmpty ||
          e.key.contains(RegExp(r'[\r\n:]')) ||
          e.value.contains(RegExp(r'[\r\n]')),
    )) {
      throw const FormatException('自定义请求头格式无效');
    }
    if (temperature != null &&
        (!temperature!.isFinite || temperature! < 0 || temperature! > 2)) {
      throw const FormatException('temperature 应为 0–2');
    }
  }

  AgentThinkingLevel thinking(String? id) => thinkingLevels.firstWhere(
    (e) => e.id == id,
    orElse: () => thinkingLevels.firstWhere(
      (e) => e.id == defaultThinking,
      orElse: () => thinkingLevels.first,
    ),
  );
  AgentJson toJson() => {
    'id': id,
    'name': name,
    'base_url': baseUrl,
    'model': model,
    'supports_vision': supportsVision,
    'include_reasoning_in_context': includeReasoning,
    'stream': stream,
    'thinking_levels': thinkingLevels.map((e) => e.toJson()).toList(),
    'default_thinking': defaultThinking,
    'extra_body': extraBody,
    'headers': headers,
    'context_window_tokens': contextWindowTokens,
    'temperature': temperature,
  };
}

class AgentSettings {
  final List<AgentModel> models;
  final String? defaultModelId;
  final String confirmPolicy;
  const AgentSettings({
    this.models = const [],
    this.defaultModelId,
    this.confirmPolicy = 'never',
  });
  factory AgentSettings.fromJson(AgentJson json) => AgentSettings(
    models: (json['models'] as List? ?? [])
        .map((e) => AgentModel.fromJson(agentObject(e)))
        .toList(),
    defaultModelId: json['default_model_id'] as String?,
    confirmPolicy: json['confirm_policy'] as String? ?? 'never',
  );
  AgentModel? findModel(String? id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  AgentModel? get defaultModel =>
      findModel(defaultModelId) ?? (models.isEmpty ? null : models.first);
  AgentJson toJson() => {
    'version': 1,
    'models': models.map((e) => e.toJson()).toList(),
    'default_model_id': defaultModelId,
    'confirm_policy': confirmPolicy,
  };
}

class AgentComic {
  final String sourceKey;
  final String comicId;
  final String title;
  final String subtitle;
  final String cover;
  final String description;
  final List<String> tags;
  const AgentComic({
    required this.sourceKey,
    required this.comicId,
    required this.title,
    this.subtitle = '',
    this.cover = '',
    this.description = '',
    this.tags = const [],
  });
  String get identity => jsonEncode([sourceKey, comicId]);
  AgentJson get ref => {'source_key': sourceKey, 'comic_id': comicId};
  factory AgentComic.fromJson(AgentJson json) => AgentComic(
    sourceKey: json['source_key'] as String,
    comicId: json['comic_id'] as String,
    title: json['title'] as String,
    subtitle: json['subtitle'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    description: json['description'] as String? ?? '',
    tags: List<String>.from(json['tags'] as List? ?? []),
  );
  AgentJson toJson() => {
    ...ref,
    'title': title,
    'subtitle': subtitle,
    'cover': cover,
    'description': description,
    'tags': tags,
  };
}

class AgentConversation {
  final String id;
  String title;
  String? modelId;
  String? thinkingId;
  final int createdAt;
  int updatedAt;
  int messageCount;
  int storageBytes;
  AgentConversation({
    required this.id,
    this.title = '新对话',
    this.modelId,
    this.thinkingId,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.storageBytes = 0,
  });
}

class AgentImageAttachment {
  final String id;
  final String name;
  final String mimeType;
  final int byteLength;
  const AgentImageAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.byteLength,
  });
  factory AgentImageAttachment.fromJson(AgentJson json) => AgentImageAttachment(
    id: json['id'] as String,
    name: json['name'] as String,
    mimeType: json['mime_type'] as String,
    byteLength: json['byte_length'] as int,
  );
  AgentJson toJson() => {
    'type': 'image',
    'id': id,
    'name': name,
    'mime_type': mimeType,
    'byte_length': byteLength,
  };
}

class AgentImageDraft {
  final AgentImageAttachment attachment;
  final Uint8List bytes;
  const AgentImageDraft(this.attachment, this.bytes);
}

String agentFormatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class AgentMessage {
  final String id;
  final String conversationId;
  final String role;
  final List<AgentJson> parts;
  final String? modelId;
  final String? thinkingId;
  final int createdAt;
  String state;
  String? error;
  AgentMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.parts,
    this.modelId,
    this.thinkingId,
    required this.createdAt,
    this.state = 'done',
    this.error,
  });
  String get text => parts
      .where((p) => p['type'] == 'text')
      .map((p) => p['text'] as String? ?? '')
      .join();
  Iterable<AgentJson> get tools => parts.where((p) => p['type'] == 'tool_call');
  List<AgentImageAttachment> get images => parts
      .where((p) => p['type'] == 'image')
      .map(AgentImageAttachment.fromJson)
      .toList();
  String? get followUpTo {
    if (role != 'user') return null;
    for (final part in parts) {
      if (part['follow_up_to'] is String) return part['follow_up_to'] as String;
    }
    return null;
  }

  bool get isFollowUp => followUpTo != null;
  void appendText(String type, String text) {
    if (text.isEmpty) return;
    if (parts.isNotEmpty && parts.last['type'] == type) {
      parts.last['text'] = (parts.last['text'] as String) + text;
    } else {
      parts.add({'type': type, 'text': text});
    }
  }
}

class AgentShowcase {
  final String id;
  final String title;
  final String note;
  final int createdAt;
  final List<AgentComic> comics;
  final String kind;
  final String? folder;
  const AgentShowcase({
    required this.id,
    required this.title,
    required this.note,
    required this.createdAt,
    required this.comics,
    this.kind = 'discovery',
    this.folder,
  });
}
