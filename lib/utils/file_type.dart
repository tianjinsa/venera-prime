import 'package:mime/mime.dart';

class FileType {
  final String ext;
  final String mime;

  const FileType(this.ext, this.mime);

  static FileType fromExtension(String ext) {
    if (ext.startsWith('.')) {
      ext = ext.substring(1);
    }
    var mime = lookupMimeType('no-file.$ext') ?? 'application/octet-stream';
    // Android doesn't support some mime types
    mime = switch (mime) {
      'text/javascript' => 'application/octet-stream',
      'application/x-cbr' => 'application/octet-stream',
      _ => mime,
    };
    return FileType(".$ext", mime);
  }
}

final _resolver = MimeTypeResolver()
  // zip
  ..addMagicNumber([0x50, 0x4B], 'application/zip')
  // 7z
  ..addMagicNumber([
    0x37,
    0x7A,
    0xBC,
    0xAF,
    0x27,
    0x1C,
  ], 'application/x-7z-compressed')
  // rar
  ..addMagicNumber([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 'application/vnd.rar');

int _uint32(List<int> data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

bool _isAvif(List<int> data) {
  var offset = 0;
  while (data.length - offset >= 8) {
    final remaining = data.length - offset;
    var size = _uint32(data, offset);
    var headerSize = 8;
    if (size == 1) {
      // ISO BMFF's extended size includes the complete 16-byte header.
      if (remaining < 16) return false;
      final high = _uint32(data, offset + 8);
      if (high > remaining ~/ 0x100000000) return false;
      size = high * 0x100000000 + _uint32(data, offset + 12);
      headerSize = 16;
    } else if (size == 0) {
      // A zero-sized box extends to the end of the file.
      size = remaining;
    }
    if (size < headerSize || size > remaining) return false;
    if (_uint32(data, offset + 4) == 0x66747970) {
      // ftyp: major_brand, minor_version, then aligned compatible brands.
      if (size < headerSize + 8 || (size - headerSize - 8) % 4 != 0) {
        return false;
      }
      bool isAvifBrand(int position) {
        final brand = _uint32(data, position);
        return brand == 0x61766966 || brand == 0x61766973; // avif / avis
      }

      if (isAvifBrand(offset + headerSize)) return true;
      for (
        var position = offset + headerSize + 8;
        position < offset + size;
        position += 4
      ) {
        if (isAvifBrand(position)) return true;
      }
      return false;
    }
    offset += size;
  }
  return false;
}

FileType detectFileType(List<int> data) {
  if (_isAvif(data)) return const FileType('.avif', 'image/avif');
  var mime = _resolver.lookup('no-file', headerBytes: data);
  var ext = mime == null ? '' : extensionFromMime(mime);
  if (ext == 'jpe') {
    ext = 'jpg';
  }
  return FileType(".$ext", mime ?? 'application/octet-stream');
}
