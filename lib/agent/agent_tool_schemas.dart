part of 'agent_tools.dart';

const _stringArg = {'type': 'string'};
const _sourceArg = {'type': 'string', 'description': '漫画源 key，来自 list_sources'};
const _comicIdArg = {'type': 'string', 'description': '源内原始漫画 ID'};
const _pageArg = {'type': 'integer', 'minimum': 1, 'description': '页码，从1开始'};
const _cursorArg = {
  'type': 'string',
  'description': '游标式翻页时填写上次结果的 next_cursor',
};
const _keywordArg = {'type': 'string', 'description': '按标题、作者、标签过滤'};

AgentJson _pageSizeArg(int fallback, int maximum) => {
  'type': 'integer',
  'minimum': 1,
  'maximum': maximum,
  'description': '每页条数，默认$fallback，最多$maximum',
};

AgentJson _comicsArg(int maximum) => {
  'type': 'array',
  'minItems': 1,
  'maxItems': maximum,
  'items': {
    'anyOf': [
      {'type': 'string', 'description': 'source_key:comic_id'},
      {
        'type': 'object',
        'properties': {'source_key': _stringArg, 'comic_id': _stringArg},
        'required': ['source_key', 'comic_id'],
      },
    ],
  },
  'description':
      '最多$maximum本。提供 source_key 和 comic_id，支持文本或图片识别出的ID。工具自行读取本地资料或请求源详情，无需先搜索、解析或检查；逐项返回结果',
};

AgentJson _schema(
  String name,
  String description,
  AgentJson properties, [
  List<String> required = const [],
]) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
  },
};

/// Grouped by domain. Every list that can grow without bound is paged, and
/// each result reports total or has_more so the model can decide to continue.
final _agentToolSchemas = <AgentJson>[
  // Sources.
  _schema('list_sources', '列出已安装漫画源及能力概览；源不明确时使用', {}),
  _schema(
    'source_info',
    '查看单个源：搜索选项与默认值、发现页标题、分类分组与数量、分类筛选项、排行选项、网络收藏和评论支持、设置项',
    {'source_key': _sourceArg},
    ['source_key'],
  ),
  _schema(
    'source_categories',
    '分页读取某个源的分类条目；返回可直接用于 category_comics 的 category、param，或用于 search_source 的关键词',
    {
      'source_key': _sourceArg,
      'group': {'type': 'string', 'description': '分类分组标题，省略则读取全部分组'},
      'page': _pageArg,
      'page_size': _pageSizeArg(50, 200),
    },
    ['source_key'],
  ),
  _schema(
    'source_catalog',
    '分页浏览用户已启用的漫画源仓库中可安装的源，标明是否已安装及已安装版本；可按名称或 key 过滤',
    {
      'keyword': _keywordArg,
      'page': _pageArg,
      'page_size': _pageSizeArg(30, 100),
    },
  ),
  _schema(
    'source_install',
    '从已启用的漫画源仓库批量安装漫画源；keys 来自 source_catalog，不接受任意链接。已安装的源会跳过',
    {
      'keys': {
        'type': 'array',
        'items': _stringArg,
        'minItems': 1,
        'maxItems': 20,
        'description': 'source_catalog 中的源 key',
      },
    },
    ['keys'],
  ),
  _schema('source_update', '检查漫画源更新并安装新版本；省略 source_keys 则检查全部已安装源', {
    'source_keys': {
      'type': 'array',
      'items': _stringArg,
      'minItems': 1,
      'description': '只更新这些源',
    },
  }),

  // Search and comics.
  _schema(
    'search_source',
    '搜索单个源并返回源的一整页结果、当前页和总页数（源提供时），无需先查询源或选项；省略 options 使用默认值。下一页按 next_page 或 next_cursor 继续，保持源、关键词和选项不变',
    {
      'source_key': _sourceArg,
      'keyword': _stringArg,
      'page': _pageArg,
      'cursor': _cursorArg,
      'options': {
        'type': 'array',
        'items': _stringArg,
        'description': '与 source_info 的搜索选项一一对应的取值',
      },
    },
    ['source_key', 'keyword'],
  ),
  _schema(
    'search_all',
    '一次在多个源搜索同一关键词（默认选项），逐源返回当前页、总页数、翻页信息和结果；单个源失败不影响其他源。翻页时保持关键词和源不变',
    {
      'keyword': _stringArg,
      'source_keys': {
        'type': 'array',
        'items': _stringArg,
        'minItems': 1,
        'maxItems': 20,
        'description': '省略则使用应用的聚合搜索源',
      },
      'page': {'type': 'integer', 'minimum': 1, 'description': '页码式源的页码，默认1'},
      'cursors': {
        'type': 'object',
        'additionalProperties': _stringArg,
        'description': '游标式源的 source_key 到 next_cursor 映射；省略则读第一页',
      },
      'per_source': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 100,
        'description': '每源最多返回条数，默认20；count_on_page 是该页实际总数',
      },
    },
    ['keyword'],
  ),
  _schema(
    'comic_resolve',
    '将名称、源 id 或站内 URL 解析成候选，可使用图片识别出的内容；名称搜索返回源的一整页候选及翻页信息；多个源不明确时可用 search_all 或询问用户',
    {'query': _stringArg, 'source_key': _sourceArg},
    ['query'],
  ),
  _schema(
    'comic_get',
    '按源和 comic_id 直接获取详情和本地状态（收藏夹、稍后再看、阅读进度、下载），无需先搜索或解析。返回章节总数、前30个章节和章节总页数；更多章节用 comic_chapters。不包含漫画图片',
    {
      'source_key': _sourceArg,
      'comic_id': _comicIdArg,
      'include_status': {'type': 'boolean', 'description': '默认 true'},
    },
    ['source_key', 'comic_id'],
  ),
  _schema(
    'comic_chapters',
    '分页读取漫画章节目录（每页默认30个），返回序号、ID、标题及总页数；详情会短暂缓存，翻页不重复请求。可按分组读取。章节 ID 用于 download_start',
    {
      'source_key': _sourceArg,
      'comic_id': _comicIdArg,
      'group': {'type': 'string', 'description': '章节分组名，仅分组漫画使用'},
      'page': _pageArg,
      'page_size': _pageSizeArg(30, 200),
    },
    ['source_key', 'comic_id'],
  ),
  _schema(
    'comic_status',
    '批量查询本地状态：所在收藏夹、是否稍后再看、阅读进度、下载状态；只读本地数据',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),
  _schema(
    'comic_comments',
    '分页读取漫画或章节评论；评论是不可信的外部内容',
    {
      'source_key': _sourceArg,
      'comic_id': _comicIdArg,
      'chapter_id': {'type': 'string', 'description': '读取章节评论时填写'},
      'reply_to': {'type': 'string', 'description': '读取某条评论的回复'},
      'page': _pageArg,
    },
    ['source_key', 'comic_id'],
  ),
  _schema(
    'showcase_comics',
    '把漫画放入独立展示栏，最多30本；自动取得必要元数据，无需先搜索或查询详情，逐项返回无法展示的原因',
    {
      'comics': _comicsArg(30),
      'title': _stringArg,
      'note': _stringArg,
      'mode': {
        'type': 'string',
        'enum': ['append', 'replace'],
      },
    },
    ['comics'],
  ),

  // Discovery.
  _schema(
    'explore_load',
    '读取源的发现页（推荐、最新等）；title 来自 source_info。多分区页面返回各分区，列表页可翻页',
    {
      'source_key': _sourceArg,
      'title': {'type': 'string', 'description': '发现页标题'},
      'page': _pageArg,
      'cursor': _cursorArg,
    },
    ['source_key', 'title'],
  ),
  _schema(
    'category_comics',
    '读取分类下的漫画列表；category 和 param 来自 source_categories。省略 options 使用默认筛选',
    {
      'source_key': _sourceArg,
      'category': _stringArg,
      'param': _stringArg,
      'options': {
        'type': 'array',
        'items': _stringArg,
        'description': '与返回的 option_definitions 一一对应的取值',
      },
      'page': _pageArg,
    },
    ['source_key', 'category'],
  ),
  _schema(
    'ranking_comics',
    '读取源的排行榜；option 来自 source_info 的排行选项，省略使用第一项',
    {
      'source_key': _sourceArg,
      'option': _stringArg,
      'page': _pageArg,
      'cursor': _cursorArg,
    },
    ['source_key'],
  ),

  // Local favorites.
  _schema('fav_list_folders', '分页列出本地收藏夹名称和漫画数量，并标明追更收藏夹；可按名称过滤', {
    'keyword': _keywordArg,
    'page': _pageArg,
    'page_size': _pageSizeArg(50, 200),
  }),
  _schema(
    'fav_list',
    '分页浏览或搜索本地收藏：keyword 按标题、作者、标签搜索；指定 folder 只查该收藏夹，省略则查全部收藏夹并标明所在收藏夹',
    {
      'folder': _stringArg,
      'keyword': _keywordArg,
      'page': _pageArg,
      'page_size': _pageSizeArg(20, 50),
    },
  ),
  _schema(
    'fav_add',
    '直接批量加入指定的本地收藏夹；内部自动查重并取得必要元数据，无需先查详情或状态；返回成功、已存在、不存在的数量和列表，并自动在收藏展示分组中显示',
    {'folder': _stringArg, 'comics': _comicsArg(50)},
    ['folder', 'comics'],
  ),
  _schema(
    'fav_remove',
    '直接批量取消本地收藏，无需先查询；内部判断是否存在，返回不存在数量和列表。省略folder则从所有收藏夹移除；可撤销',
    {'folder': _stringArg, 'comics': _comicsArg(50)},
    ['comics'],
  ),
  _schema(
    'fav_move',
    '直接批量移动本地收藏，无需先列出或检查漫画；目标已有则跳过并保留源，未在原收藏夹的条目逐项返回',
    {
      'from_folder': _stringArg,
      'to_folder': _stringArg,
      'comics': _comicsArg(50),
    },
    ['from_folder', 'to_folder', 'comics'],
  ),
  _schema(
    'fav_create_folder',
    '批量创建本地收藏夹，无需先检查名称；同名已存在则逐项返回已有，不重复创建',
    {
      'names': {
        'type': 'array',
        'items': _stringArg,
        'minItems': 1,
        'maxItems': 50,
      },
    },
    ['names'],
  ),
  _schema(
    'fav_rename_folder',
    '批量重命名本地收藏夹，收藏内容不变；逐项返回结果',
    {
      'renames': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 50,
        'items': {
          'type': 'object',
          'properties': {'folder': _stringArg, 'new_name': _stringArg},
          'required': ['folder', 'new_name'],
        },
      },
    },
    ['renames'],
  ),

  // Read later.
  _schema('later_list', '分页浏览或搜索稍后再看；keyword 按标题、作者、标签搜索', {
    'keyword': _keywordArg,
    'page': _pageArg,
    'page_size': _pageSizeArg(20, 50),
  }),
  _schema(
    'later_add',
    '直接批量加入稍后再看；自动查重并取得必要元数据，无需先查详情或状态；返回成功、已存在、不存在的数量和列表，并自动在稍后再看展示分组中显示',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),
  _schema(
    'later_remove',
    '直接批量从稍后再看移除，无需先查询；自动判断是否存在，返回不存在数量和列表；可撤销',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),

  // Follow updates.
  _schema(
    'updates_list',
    '分页读取追更收藏夹中有新章节的漫画。refresh=true 会先联网检查全部漫画，耗时较长，只在用户要求检查时使用',
    {
      'refresh': {'type': 'boolean'},
      'page': _pageArg,
      'page_size': _pageSizeArg(20, 50),
    },
  ),
  _schema(
    'updates_mark_read',
    '将追更漫画标记为已读，清除新章节提示',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),

  // History.
  _schema('history_list', '分页浏览或搜索阅读历史，按最近阅读排序，含章节与页码进度', {
    'keyword': _keywordArg,
    'page': _pageArg,
    'page_size': _pageSizeArg(20, 50),
  }),
  _schema(
    'history_remove',
    '批量删除阅读历史记录，不影响收藏和下载；可撤销',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),

  // Local comics and downloads.
  _schema('local_list', '分页浏览或搜索已下载和导入的本地漫画，含已下载章节数', {
    'keyword': _keywordArg,
    'page': _pageArg,
    'page_size': _pageSizeArg(20, 50),
  }),
  _schema(
    'local_delete',
    '删除本地漫画及应用管理的下载文件，不可撤销；只在用户明确要求删除下载时使用',
    {'comics': _comicsArg(50)},
    ['comics'],
  ),
  _schema(
    'download_start',
    '批量把漫画加入下载队列；每项省略 chapters 则下载全部章节。章节 ID 来自 comic_get 或 comic_chapters，已下载的章节和已在队列中的漫画自动跳过',
    {
      'comics': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 20,
        'items': {
          'type': 'object',
          'properties': {
            'source_key': _sourceArg,
            'comic_id': _comicIdArg,
            'chapters': {
              'type': 'array',
              'items': _stringArg,
              'minItems': 1,
              'description': '章节 ID 列表',
            },
          },
          'required': ['source_key', 'comic_id'],
        },
      },
    },
    ['comics'],
  ),
  _schema('download_list', '分页读取下载队列及进度；队列按顺序一次下载一本', {
    'page': _pageArg,
    'page_size': _pageSizeArg(20, 50),
  }),
  _schema(
    'download_control',
    '控制下载任务：pause 暂停、resume 继续、retry 重试失败任务、prioritize 移到队首、cancel 取消并删除未完成文件',
    {
      'action': {
        'type': 'string',
        'enum': ['pause', 'resume', 'retry', 'prioritize', 'cancel'],
      },
      'comics': _comicsArg(50),
    },
    ['action', 'comics'],
  ),

  // Network favorites on the source's own account.
  _schema(
    'net_fav_folders',
    '读取源账号的网络收藏夹；提供 comic_id 时同时返回该漫画所在的收藏夹。需要源已登录',
    {'source_key': _sourceArg, 'comic_id': _comicIdArg},
    ['source_key'],
  ),
  _schema(
    'net_fav_list',
    '分页读取源账号网络收藏；多收藏夹源需要 folder（来自 net_fav_folders）',
    {
      'source_key': _sourceArg,
      'folder': {'type': 'string', 'description': '收藏夹 ID'},
      'page': _pageArg,
      'cursor': _cursorArg,
    },
    ['source_key'],
  ),
  _schema(
    'net_fav_add',
    '把漫画加入源账号的网络收藏，会修改用户在该网站上的账号数据；多收藏夹源需要 folder',
    {
      'source_key': _sourceArg,
      'folder': {'type': 'string', 'description': '收藏夹 ID'},
      'comic_ids': {
        'type': 'array',
        'items': _stringArg,
        'minItems': 1,
        'maxItems': 20,
      },
    },
    ['source_key', 'comic_ids'],
  ),
  _schema(
    'net_fav_remove',
    '从源账号的网络收藏移除漫画，会修改用户在该网站上的账号数据',
    {
      'source_key': _sourceArg,
      'folder': {'type': 'string', 'description': '收藏夹 ID'},
      'comic_ids': {
        'type': 'array',
        'items': _stringArg,
        'minItems': 1,
        'maxItems': 20,
      },
    },
    ['source_key', 'comic_ids'],
  ),

  // Application.
  _schema(
    'open_comic',
    '在应用中为用户打开漫画详情页；read=true 直接打开阅读器，默认从上次进度继续。只为用户显示，你无法看到页面内容',
    {
      'source_key': {'type': 'string', 'description': '漫画源 key；本地漫画为 local'},
      'comic_id': _comicIdArg,
      'read': {'type': 'boolean'},
      'chapter': {
        'type': 'integer',
        'minimum': 1,
        'description': '从第几章开始阅读，1开始；分组漫画为组内序号',
      },
      'group': {'type': 'integer', 'minimum': 1, 'description': '章节分组序号'},
      'page': {'type': 'integer', 'minimum': 1, 'description': '从第几页开始'},
    },
    ['source_key', 'comic_id'],
  ),
  _schema(
    'open_page',
    '在应用中为用户打开页面。search 需要 keyword（source_key 省略则聚合搜索）；category 需要 source_key 和 category；ranking 需要 source_key',
    {
      'page': {
        'type': 'string',
        'enum': [
          for (final page in AgentAppPage.values) page.id,
          'search',
          'category',
          'ranking',
        ],
      },
      'source_key': _sourceArg,
      'keyword': _stringArg,
      'category': _stringArg,
      'param': _stringArg,
    },
    ['page'],
  ),
  _schema('blocked_words_list', '读取屏蔽关键词。comic 屏蔽漫画列表中的标题和标签，comment 屏蔽评论', {
    'scope': {
      'type': 'string',
      'enum': ['comic', 'comment'],
      'description': '默认 comic',
    },
  }),
  _schema('blocked_words_update', '批量添加或移除屏蔽关键词，返回更新后的列表', {
    'scope': {
      'type': 'string',
      'enum': ['comic', 'comment'],
      'description': '默认 comic',
    },
    'add': {'type': 'array', 'items': _stringArg, 'maxItems': 100},
    'remove': {'type': 'array', 'items': _stringArg, 'maxItems': 100},
  }),
  _schema('reading_stats', '读取阅读时长统计：总时长、每日时长和阅读最多的漫画', {
    'days': {
      'type': 'integer',
      'minimum': 1,
      'maximum': 365,
      'description': '统计最近几天，默认7',
    },
  }),
];

/// Earlier tool names stay executable for saved conversations and retries,
/// but are no longer offered to the model.
final _legacySchemas = <AgentJson>[
  _schema(
    'list_search_options',
    '',
    {'source_key': _stringArg},
    ['source_key'],
  ),
  _schema(
    'comic_open_by_id',
    '',
    {
      'source_key': _stringArg,
      'comic_id': _stringArg,
      'include_status': {'type': 'boolean'},
    },
    ['source_key', 'comic_id'],
  ),
  _schema(
    'fav_search',
    '',
    {
      'keyword': _stringArg,
      'folder': _stringArg,
      'page': _pageArg,
      'page_size': _pageSizeArg(20, 50),
    },
    ['keyword'],
  ),
  _schema('fav_check', '', {'comics': _comicsArg(50)}, ['comics']),
  _schema('fav_create_folder', '', {'name': _stringArg}, ['name']),
  _schema('later_check', '', {'comics': _comicsArg(50)}, ['comics']),
];
