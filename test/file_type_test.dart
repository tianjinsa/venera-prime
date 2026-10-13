import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/file_type.dart';

List<int> _u32(int value) => [
  (value >> 24) & 255,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];

List<int> _box(String type, List<int> payload, {bool extended = false}) => [
  ..._u32(extended ? 1 : 8 + payload.length),
  ...type.codeUnits,
  if (extended) ...[..._u32(0), ..._u32(16 + payload.length)],
  ...payload,
];

List<int> _ftyp(
  String major, {
  List<String> compatible = const [],
  int minor = 0,
  bool extended = false,
}) => _box('ftyp', [
  ...major.codeUnits,
  ..._u32(minor),
  for (final brand in compatible) ...brand.codeUnits,
], extended: extended);

void _expectAvif(List<int> data) {
  final type = detectFileType(data);
  expect(type.mime, 'image/avif');
  expect(type.ext, '.avif');
}

void main() {
  test('AVIF major brands support different ftyp lengths and sequences', () {
    for (final brand in ['avif', 'avis']) {
      for (final compatible in [
        <String>[],
        ['mif1'],
        ['mif1', 'miaf'],
        ['mif1', 'miaf', 'MA1B', 'av01'],
      ]) {
        _expectAvif(_ftyp(brand, compatible: compatible));
      }
    }
  });

  test('AVIF compatible brands override generic HEIF and MP4 magic', () {
    _expectAvif(_ftyp('mif1', compatible: ['miaf', 'avif', 'MA1B']));
    _expectAvif(_ftyp('msf1', compatible: ['avis', 'iso8']));
    _expectAvif(_ftyp('avc1', compatible: ['avif']));
  });

  test(
    'ISO BMFF extended headers and complete preceding boxes are handled',
    () {
      _expectAvif(_ftyp('avif', extended: true));
      _expectAvif(_ftyp('mif1', compatible: ['avif'], extended: true));
      _expectAvif([
        ..._box('free', [1, 2, 3, 4], extended: true),
        ..._ftyp('avis'),
        ..._box('mdat', [1, 2, 3]),
      ]);
      final throughEof = _ftyp('avif', compatible: ['mif1']);
      throughEof.setRange(0, 4, _u32(0));
      _expectAvif(throughEof);
    },
  );

  test('truncated ftyp headers and payloads do not match or throw', () {
    for (final complete in [
      _ftyp('avif', compatible: ['mif1', 'miaf']),
      _ftyp('mif1', compatible: ['avif'], extended: true),
    ]) {
      for (var length = 0; length < complete.length; length++) {
        expect(
          detectFileType(complete.sublist(0, length)).mime,
          isNot('image/avif'),
          reason: 'length $length of ${complete.length}',
        );
      }
    }
  });

  test('malformed box sizes and incomplete brand entries are rejected', () {
    final valid = _ftyp('avif');
    for (final size in [2, 7, 8, 12, 15, 17, 0xffffffff]) {
      final malformed = [..._u32(size), ...valid.skip(4)];
      expect(detectFileType(malformed).mime, isNot('image/avif'));
    }
    for (final size in [0, 8, 16, 23, 25, 0xffffffff]) {
      final malformed = _ftyp('avif', extended: true);
      malformed.setRange(12, 16, _u32(size));
      expect(detectFileType(malformed).mime, isNot('image/avif'));
    }
    final hugeExtended = _ftyp('avif', extended: true);
    hugeExtended.setRange(8, 12, _u32(0xffffffff));
    expect(detectFileType(hugeExtended).mime, isNot('image/avif'));
    expect(
      detectFileType(_box('ftyp', [...valid.skip(8), 1])).mime,
      isNot('image/avif'),
    );
  });

  test('only aligned brands inside the first ftyp box count', () {
    final cases = [
      'not a file: avif and avis'.codeUnits,
      _ftyp('mif1', minor: 0x61766966), // minor_version is not a brand.
      _ftyp('mif1', compatible: ['xavi', 'fxxx']),
      _box('mdat', _ftyp('avif')), // Nested data is not a top-level box.
      [..._ftyp('mif1'), ..._box('mdat', 'avif'.codeUnits)],
      [..._ftyp('mif1'), ..._ftyp('avif')],
      [..._u32(7), ...'free'.codeUnits, ..._ftyp('avif')],
      [..._u32(0), ...'free'.codeUnits, ..._ftyp('avif')],
    ];
    for (final bytes in cases) {
      expect(detectFileType(bytes).mime, isNot('image/avif'));
    }
  });

  test('non-AVIF MIME and extension detection remains unchanged', () {
    final fixtures = <(List<int>, String, String)>[
      ([0xff, 0xd8, 0xff], 'image/jpeg', '.jpg'),
      ([137, 80, 78, 71, 13, 10, 26, 10], 'image/png', '.png'),
      ('GIF89a'.codeUnits, 'image/gif', '.gif'),
      ([0x50, 0x4b, 3, 4], 'application/zip', '.zip'),
      (
        [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
        'application/x-7z-compressed',
        '.7z',
      ),
      (_ftyp('avc1'), 'video/mp4', '.mp4'),
      (_ftyp('mif1'), 'image/heif', '.heif'),
      (_ftyp('heic'), 'image/heic', '.heic'),
      ([], 'application/octet-stream', '.'),
    ];
    for (final (data, mime, ext) in fixtures) {
      final type = detectFileType(data);
      expect(type.mime, mime);
      expect(type.ext, ext);
    }
    expect(FileType.fromExtension('.avif').mime, 'image/avif');
    expect(FileType.fromExtension('png').ext, '.png');
    expect(FileType.fromExtension('js').mime, 'application/octet-stream');
  });
}
