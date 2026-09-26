import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Split [text] into bounded chunks at line breaks. Boundaries depend only on
/// the preceding text, so a growing streamed text keeps every earlier chunk.
/// CRLF pairs and UTF-16 surrogate pairs are never split.
List<String> agentTextChunks(String text, {int size = 2048}) {
  if (text.length <= size) return [text];
  final chunks = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = math.min(start + size, text.length);
    if (end < text.length) {
      final lineEnd = text.lastIndexOf('\n', end - 1);
      if (lineEnd >= start + size ~/ 2) {
        end = lineEnd + 1;
      } else {
        // A very long line without breaks: only a complete window is final.
        final previous = text.codeUnitAt(end - 1);
        final next = text.codeUnitAt(end);
        if (previous == 13 && next == 10 ||
            previous >= 0xd800 &&
                previous <= 0xdbff &&
                next >= 0xdc00 &&
                next <= 0xdfff) {
          end--;
        }
      }
    }
    chunks.add(text.substring(start, end));
    start = end;
  }
  return chunks;
}

/// Selectable plain text that never claims vertical drags.
///
/// SelectableText wraps its content in its own vertical Scrollable, which wins
/// the drag gesture even when there is nothing to scroll, so a drag that starts
/// on it cannot move the surrounding conversation. A SelectionArea over plain
/// Text keeps long-press selection and copying while drags reach the list.
/// Long text is laid out in stable chunks so appending re-lays out only the
/// last one.
class AgentSelectableText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const AgentSelectableText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final chunks = agentTextChunks(text);
    return SelectionArea(
      child: chunks.length == 1
          ? Text(text, style: style)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < chunks.length; i++)
                  Text(
                    _trimChunk(chunks[i], i == chunks.length - 1),
                    key: ValueKey(i),
                    style: style,
                  ),
              ],
            ),
    );
  }
}

/// The next Text starts on a new line already; drop the separating newline so
/// chunk boundaries do not render an extra blank line.
String _trimChunk(String chunk, bool last) {
  if (last || !chunk.endsWith('\n')) return chunk;
  var end = chunk.length - 1;
  if (end > 0 && chunk.codeUnitAt(end - 1) == 13) end--;
  return chunk.substring(0, end);
}

final _listItem = RegExp(r'^([-*+]|\d{1,9}[.)])(\s|$)');

/// Split long Markdown into independently renderable chunks.
///
/// A chunk ends only before an unindented line that follows a blank line and
/// is outside a fenced code block, and is not a list item that could continue
/// a list. Boundaries depend only on the text before them, so a streamed
/// response keeps its earlier chunks and only the last one is parsed again.
List<String> agentMarkdownChunks(String text, {int size = 1500}) {
  if (text.length <= size) return [text];
  final chunks = <String>[];
  var start = 0;
  var lineStart = 0;
  String? fence;
  var previousBlank = false;
  while (lineStart < text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? text.length : newline;
    final line = text.substring(lineStart, lineEnd);
    final first = line.isEmpty ? 0 : line.codeUnitAt(0);
    if (fence == null &&
        previousBlank &&
        lineStart - start >= size &&
        line.isNotEmpty &&
        first != 32 &&
        first != 9 &&
        !_listItem.hasMatch(line)) {
      chunks.add(text.substring(start, lineStart));
      start = lineStart;
    }
    final trimmed = line.trimLeft();
    if (fence == null) {
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        fence = trimmed.substring(0, 3);
      }
    } else if (trimmed.startsWith(fence)) {
      fence = null;
    }
    previousBlank = line.trim().isEmpty;
    lineStart = newline < 0 ? text.length : newline + 1;
  }
  chunks.add(text.substring(start));
  return chunks;
}
