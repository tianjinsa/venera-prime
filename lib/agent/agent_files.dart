import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:venera/utils/io.dart' show IO;

import 'agent_models.dart';

const agentTextFileMaxBytes = 20 * 1024 * 1024;

Future<List<AgentTextDraft>> pickAgentTextFiles() => IO.withFileSelection(
  () async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '文本文件',
          extensions: [
            'txt',
            'md',
            'csv',
            'tsv',
            'json',
            'jsonl',
            'ndjson',
            'xml',
            'yaml',
            'yml',
            'log',
            'ini',
            'conf',
            'toml',
            'sql',
          ],
          mimeTypes: [
            'text/*',
            'application/json',
            'application/x-ndjson',
            'application/xml',
            'application/yaml',
          ],
          uniformTypeIdentifiers: ['public.text', 'public.json', 'public.xml'],
        ),
        // Also allow extensionless and uncommon text files. The selected bytes
        // are decoded and checked below, independently of the picker filter.
        XTypeGroup(label: '所有文件'),
      ],
    );
    return [for (final file in files) await readAgentTextFile(file)];
  },
);

Future<AgentTextDraft> readAgentTextFile(XFile file) async {
  if (await file.length() > agentTextFileMaxBytes) {
    throw AgentException('FILE_TOO_LARGE', '文件“${file.name}”超过20 MB，请拆分后添加');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > agentTextFileMaxBytes) {
    throw AgentException('FILE_TOO_LARGE', '文件“${file.name}”超过20 MB，请拆分后添加');
  }
  final extension = file.name.split('.').last.toLowerCase();
  if (const {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'odt',
    'ods',
    'odp',
    'rtf',
    'pages',
    'numbers',
    'key',
  }.contains(extension)) {
    throw const AgentException(
      'INVALID_TEXT_FILE',
      '暂不支持 PDF、Office 或富文本文件，请导出为 TXT、CSV 或 JSON 等纯文本',
    );
  }
  try {
    // Validate actual bytes before assigning a MIME type from the filename.
    final encoding = _textEncoding(bytes);
    decodeAgentTextFile(bytes, encoding: encoding);
    return AgentTextDraft(
      AgentTextAttachment(
        id: agentId(),
        name: file.name,
        mimeType: switch (extension) {
          'csv' => 'text/csv',
          'tsv' => 'text/tab-separated-values',
          'json' => 'application/json',
          'jsonl' || 'ndjson' => 'application/x-ndjson',
          'md' => 'text/markdown',
          'xml' => 'application/xml',
          'yaml' || 'yml' => 'application/yaml',
          _ => 'text/plain',
        },
        byteLength: bytes.length,
        encoding: encoding,
      ),
      bytes,
    );
  } on AgentException catch (e) {
    throw AgentException(e.code, '文件“${file.name}”：${e.message}');
  }
}

/// Strict decoding shared by the picker, persistent storage and previews.
/// Original bytes remain unchanged, including a byte-order mark if present.
String decodeAgentTextFile(Uint8List bytes, {String? encoding}) {
  if (bytes.length > agentTextFileMaxBytes) {
    throw const AgentException('FILE_TOO_LARGE', '文本文件超过20 MB，请拆分后添加');
  }
  if (_hasBinarySignature(bytes)) {
    throw const AgentException(
      'INVALID_TEXT_FILE',
      '文件内容不是纯文本，暂不支持 PDF、Office、图片或其他二进制格式',
    );
  }
  final detected = _textEncoding(bytes);
  final selected = encoding ?? detected;
  if (!const {'utf-8', 'utf-16le', 'utf-16be'}.contains(selected)) {
    throw const AgentException(
      'UNSUPPORTED_TEXT_ENCODING',
      '请使用 UTF-8 或带 BOM 的 UTF-16 编码保存文本文件',
    );
  }
  final bomLength = _startsWith(bytes, [0xef, 0xbb, 0xbf])
      ? 3
      : _startsWith(bytes, [0xff, 0xfe]) || _startsWith(bytes, [0xfe, 0xff])
      ? 2
      : 0;
  if (bomLength != 0 && selected != detected) {
    throw const AgentException('INVALID_TEXT_FILE', '文件编码与 BOM 不一致，请重新添加');
  }
  String text;
  try {
    if (selected == 'utf-8') {
      text = utf8.decode(
        Uint8List.sublistView(bytes, bomLength),
        allowMalformed: false,
      );
    } else {
      final length = bytes.length - bomLength;
      if (length.isOdd) {
        throw const FormatException('Incomplete UTF-16 code unit');
      }
      final source = ByteData.sublistView(bytes, bomLength);
      final units = Uint16List(length ~/ 2);
      final endian = selected == 'utf-16le' ? Endian.little : Endian.big;
      var expectsLowSurrogate = false;
      for (var i = 0; i < units.length; i++) {
        final unit = source.getUint16(i * 2, endian);
        final high = unit >= 0xd800 && unit <= 0xdbff;
        final low = unit >= 0xdc00 && unit <= 0xdfff;
        if (expectsLowSurrogate != low) {
          throw const FormatException('Invalid UTF-16 surrogate');
        }
        expectsLowSurrogate = high;
        units[i] = unit;
      }
      if (expectsLowSurrogate) {
        throw const FormatException('Incomplete UTF-16 surrogate');
      }
      text = String.fromCharCodes(units);
    }
  } on FormatException {
    throw const AgentException(
      'INVALID_TEXT_FILE',
      '无法按文本编码解码，请使用 UTF-8 或带 BOM 的 UTF-16 重新保存；不会替换乱码或截断内容',
    );
  }
  if (text.codeUnits.any(
    (unit) =>
        (unit < 0x20 && !const {0x09, 0x0a, 0x0c, 0x0d}.contains(unit)) ||
        (unit >= 0x7f && unit <= 0x9f),
  )) {
    throw const AgentException('INVALID_TEXT_FILE', '检测到二进制控制字符，请选择纯文本文件');
  }
  return text;
}

String _textEncoding(Uint8List bytes) {
  if (_startsWith(bytes, [0xff, 0xfe, 0x00, 0x00]) ||
      _startsWith(bytes, [0x00, 0x00, 0xfe, 0xff])) {
    throw const AgentException(
      'UNSUPPORTED_TEXT_ENCODING',
      '暂不支持 UTF-32，请使用 UTF-8 或带 BOM 的 UTF-16 重新保存',
    );
  }
  if (_startsWith(bytes, [0xff, 0xfe])) return 'utf-16le';
  if (_startsWith(bytes, [0xfe, 0xff])) return 'utf-16be';
  return 'utf-8';
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

bool _hasBinarySignature(Uint8List bytes) => const [
  [0x25, 0x50, 0x44, 0x46, 0x2d], // PDF
  [0x50, 0x4b, 0x03, 0x04], // ZIP-based Office/OpenDocument formats
  [0x50, 0x4b, 0x05, 0x06],
  [0x50, 0x4b, 0x07, 0x08],
  [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1], // Legacy Office
  [0x7b, 0x5c, 0x72, 0x74, 0x66], // RTF
  [0x89, 0x50, 0x4e, 0x47],
  [0xff, 0xd8, 0xff],
  [0x47, 0x49, 0x46, 0x38, 0x37, 0x61],
  [0x47, 0x49, 0x46, 0x38, 0x39, 0x61],
].any((prefix) => _startsWith(bytes, prefix));
