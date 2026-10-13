import 'package:venera/foundation/comic_source/comic_source.dart';

ComicSource sourceFixture({
  List<ExplorePageData> explore = const [],
  LoadComicFunc? details,
  LoadComicPagesFunc? pages,
}) => ComicSource(
  'Fixture',
  'availability-fixture',
  null,
  null,
  null,
  null,
  explore,
  null,
  null,
  details,
  null,
  pages,
  null,
  null,
  '',
  '',
  '1',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

ComicDetails detailsFixture(
  String id, {
  Object? chapters = const {'ep': 'Chapter'},
}) => ComicDetails.fromJson({
  'title': 'Sample $id',
  'cover': '',
  'tags': <String, List<String>>{},
  'comicId': id,
  'sourceKey': 'availability-fixture',
  'chapters': chapters,
});

Comic comicFixture(String id) =>
    Comic(id, '', id, null, null, '', 'availability-fixture', null, null);
