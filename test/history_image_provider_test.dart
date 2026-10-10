import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';
import 'package:venera/foundation/res.dart';

class _CoverFile implements File {
  _CoverFile(this.bytes, {this.error});

  final Uint8List bytes;
  final Object? error;

  @override
  Future<Uint8List> readAsBytes() async {
    if (error != null) throw error!;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CoverCache implements CacheManager {
  final files = <String, File>{};
  int reads = 0;

  @override
  Future<File?> findCache(String key) async {
    reads++;
    return files[key] ?? (throw StateError('Unexpected cover request: $key'));
  }

  @override
  Future<void> delete(String key) async => files.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SavedHistory extends HistoryManager {
  _SavedHistory() : super.create();
  final saved = <History>[];

  @override
  void addHistory(History history) => saved.add(history);
}

class _NoFavorites implements LocalFavoritesManager {
  @override
  List<String> find(String id, ComicType type) => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements ComicSource {
  _Source(this.key);

  @override
  final String key;

  @override
  String get name => 'Cover test source';

  int requests = 0;
  final String newCover = 'https://example.invalid/refreshed.png';

  @override
  LoadComicFunc get loadComicInfo => (id) async {
    requests++;
    return Res(
      ComicDetails.fromJson({
        'title': 'Refreshed title',
        'subtitle': 'Refreshed author',
        'cover': newCover,
        'tags': <String, List<String>>{},
        'sourceKey': key,
        'comicId': id,
      }),
    );
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CoverCache cache;
  late _SavedHistory savedHistory;
  late _Source source;
  late CacheManager? previousCache;
  late HistoryManager? previousHistory;
  late LocalFavoritesManager? previousFavorites;
  var sequence = 0;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  );

  setUp(() {
    previousCache = CacheManager.instance;
    previousHistory = HistoryManager.cache;
    previousFavorites = LocalFavoritesManager.cache;
    cache = _CoverCache();
    savedHistory = _SavedHistory();
    CacheManager.instance = cache;
    HistoryManager.cache = savedHistory;
    LocalFavoritesManager.cache = _NoFavorites();
    source = _Source('history-cover-test-${sequence++}');
    ComicSourceManager().add(source);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicSourceManager().remove(source.key);
    CacheManager.instance = previousCache;
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    savedHistory.dispose();
  });

  History record(String id) => History.fromMap({
    'id': id,
    'type': ComicType.fromKey(source.key).value,
    'title': 'Saved title',
    'subtitle': 'Saved author',
    'cover': 'https://example.invalid/$id.png',
    'time': 1700000000000,
    'ep': 4,
    'page': 17,
    'readEpisode': ['1', '2', '3'],
    'max_page': 30,
  })..group = 2;

  void cacheCover(
    History comic, {
    String? url,
    Uint8List? bytes,
    Object? error,
  }) {
    cache.files['${url ?? comic.cover}@${source.key}@${comic.id}'] = _CoverFile(
      bytes ?? png,
      error: error,
    );
  }

  Future<Uint8List> load(History comic) async {
    final events = StreamController<ImageChunkEvent>();
    events.stream.listen((_) {});
    try {
      return await HistoryImageProvider(comic).load(events, () {});
    } finally {
      await events.close();
    }
  }

  test(
    '1200 cached covers cause no detail requests or history writes',
    () async {
      for (var i = 0; i < 1200; i++) {
        final comic = record('$i');
        cacheCover(comic);
        expect(await load(comic), png);
      }
      expect(cache.reads, 1200);
      expect(source.requests, 0);
      expect(savedHistory.saved, isEmpty);
    },
  );

  test(
    'invalid covers still recover without changing reading progress',
    () async {
      final comic = record('invalid');
      cacheCover(comic, error: const FileSystemException('Unreadable cover'));
      cacheCover(comic, url: source.newCover);

      expect(await load(comic), png);
      expect(source.requests, 1);
      expect(savedHistory.saved, [comic]);
      expect(comic.title, 'Refreshed title');
      expect(comic.cover, source.newCover);
      expect(comic.time.millisecondsSinceEpoch, 1700000000000);
      expect(comic.ep, 4);
      expect(comic.page, 17);
      expect(comic.group, 2);
      expect(comic.readEpisode, {'1', '2', '3'});
      expect(comic.maxPage, 30);
    },
  );

  test(
    'large history covers decode at thumbnail size with their aspect ratio',
    () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFF336699), BlendMode.src);
      final picture = recorder.endRecording();
      final original = await picture.toImage(2400, 3600);
      picture.dispose();
      final bytes = await original.toByteData(format: ui.ImageByteFormat.png);
      original.dispose();
      final comic = record('large');
      cacheCover(comic, bytes: bytes!.buffer.asUint8List());

      final provider = ResizeImage(
        HistoryImageProvider(comic),
        width: 320,
        height: 384,
        policy: ResizeImagePolicy.fit,
      );
      final frame = Completer<ImageInfo>();
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (image, _) => frame.complete(image),
        onError: frame.completeError,
      );
      stream.addListener(listener);
      final image = await frame.future;
      try {
        expect(image.image.width, 256);
        expect(image.image.height, 384);
        expect(image.sizeBytes, lessThan(400 * 1024));
        expect(source.requests, 0);
      } finally {
        stream.removeListener(listener);
        image.dispose();
      }
    },
  );
}
