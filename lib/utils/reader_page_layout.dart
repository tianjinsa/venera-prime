/// Maps image numbers to screens, including an independently shifted first group.
class ReaderPageLayout {
  const ReaderPageLayout({
    required this.imageCount,
    required this.imagesPerPage,
    required this.singleCover,
    this.offset = 0,
  });

  final int imageCount;
  final int imagesPerPage;
  final bool singleCover;
  final int offset;

  int get firstPageCount => imagesPerPage == 1
      ? 1
      : ((singleCover ? 0 : imagesPerPage - 1) + offset) % imagesPerPage + 1;

  int get pageCount =>
      1 +
      ((imageCount - firstPageCount).clamp(0, imageCount) / imagesPerPage)
          .ceil();

  (int, int) range(int page) {
    final start = page <= 1 ? 0 : firstPageCount + (page - 2) * imagesPerPage;
    return (
      start,
      (page <= 1 ? firstPageCount : start + imagesPerPage).clamp(0, imageCount),
    );
  }

  int pageForImage(int image) => image <= firstPageCount
      ? 1
      : 2 + (image - firstPageCount - 1) ~/ imagesPerPage;

  int offsetForStart(int start) => start == 0
      ? 0
      : (start - (singleCover ? 1 : imagesPerPage)) % imagesPerPage;
}
