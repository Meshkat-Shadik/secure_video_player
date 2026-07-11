import 'dart:io';

/// One SubRip cue. Immutable; [text] keeps original inline `<i>/<b>/<u>`
/// markup (lines joined by `\n`) so an overlay can render it styled —
/// use [plainText] for the tag-free string.
class SubtitleCue {
  const SubtitleCue({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  final int index;
  final Duration start;
  final Duration end;
  final String text;

  /// [text] with any inline markup removed.
  String get plainText => text.replaceAll(_anyTag, '');

  @override
  String toString() => 'SubtitleCue($index, $start-$end, ${plainText.length}c)';
}

/// Parses a full `.srt` document. O(n) single pass, forgiving: handles a BOM,
/// CRLF/LF/CR line endings, missing cue numbers, `.`-vs-`,` millisecond
/// separators and trailing position coords; a malformed block is skipped
/// without aborting the file. Returns an immutable, start-ordered cue list.
List<SubtitleCue> parseSrt(String data) {
  final cues = <SubtitleCue>[];
  if (data.isEmpty) return List.unmodifiable(cues);
  var s = data;
  if (s.codeUnitAt(0) == 0xFEFF) s = s.substring(1); // strip BOM
  final lines = s.split(_lineBreak);

  var i = 0;
  var auto = 0;
  while (i < lines.length) {
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length) break;
    final start = i;
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      i++;
    }
    final cue = _parseBlock(lines, start, i, ++auto);
    if (cue != null) cues.add(cue);
  }
  // Cursor lookup and interpolation both assume start-ordered cues; some files
  // ship out of order.
  cues.sort((a, b) => a.start.compareTo(b.start));
  return List.unmodifiable(cues);
}

SubtitleCue? _parseBlock(List<String> lines, int from, int to, int fallback) {
  var tc = -1;
  for (var j = from; j < to; j++) {
    if (lines[j].contains('-->')) {
      tc = j;
      break;
    }
  }
  if (tc == -1) return null; // no timecode line → skip
  final range = _parseRange(lines[tc]);
  if (range == null) return null;

  var index = fallback;
  if (tc > from) {
    final n = int.tryParse(lines[from].trim());
    if (n != null) index = n;
  }
  final text = lines.sublist(tc + 1, to).join('\n').trim();
  return SubtitleCue(
      index: index, start: range.$1, end: range.$2, text: text);
}

(Duration, Duration)? _parseRange(String line) {
  final parts = line.split('-->');
  if (parts.length < 2) return null;
  final start = _parseTs(parts[0]);
  final end = _parseTs(parts[1]);
  if (start == null || end == null) return null;
  return (start, end);
}

Duration? _parseTs(String s) {
  final m = _tsRe.firstMatch(s);
  if (m == null) return null;
  return Duration(
    hours: int.parse(m.group(1)!),
    minutes: int.parse(m.group(2)!),
    seconds: int.parse(m.group(3)!),
    milliseconds: int.parse(m.group(4)!.padRight(3, '0')),
  );
}

final _lineBreak = RegExp(r'\r\n|\r|\n');
final _tsRe = RegExp(r'(\d+):(\d{2}):(\d{2})[,.](\d{1,3})');
final _anyTag = RegExp(r'<[^>]*>');

/// Loads and parses SRT subtitles. The result renders in Flutter, independent
/// of the native pipeline — so it works with encrypted video and in texture
/// mode where native cue rendering never reaches the screen.
abstract final class SrtSubtitles {
  static List<SubtitleCue> fromString(String data) => parseSrt(data);

  static Future<List<SubtitleCue>> fromFile(String path) async =>
      parseSrt(await File(path).readAsString());
}

/// Finds the cue active at a given time. Keeps a cursor so steady playback is
/// O(1) (the active cue is at or one past the cursor); a seek in either
/// direction falls back to a binary search for the floor cue, O(log n). No
/// allocation on the query path. The delay offset is applied by the caller
/// (query with `position - delay`), so it never rebuilds the cue list.
class SubtitleCueLookup {
  SubtitleCueLookup(this.cues);

  final List<SubtitleCue> cues;
  int _cursor = 0;

  SubtitleCue? at(Duration t) => atMicros(t.inMicroseconds);

  SubtitleCue? atMicros(int tUs) {
    final n = cues.length;
    if (n == 0) return null;
    var i = _cursor;
    if (i < 0) {
      i = 0;
    } else if (i >= n) {
      i = n - 1;
    }

    final onFloor = cues[i].start.inMicroseconds <= tUs &&
        (i + 1 >= n || cues[i + 1].start.inMicroseconds > tUs);
    if (!onFloor) {
      if (i + 1 < n &&
          cues[i + 1].start.inMicroseconds <= tUs &&
          (i + 2 >= n || cues[i + 2].start.inMicroseconds > tUs)) {
        i += 1; // steady advance
      } else if (i > 0 &&
          cues[i - 1].start.inMicroseconds <= tUs &&
          cues[i].start.inMicroseconds > tUs) {
        i -= 1; // small step back
      } else {
        i = _floor(tUs); // seek → binary search
      }
    }
    _cursor = i;
    final cue = cues[i];
    return (tUs >= cue.start.inMicroseconds && tUs < cue.end.inMicroseconds)
        ? cue
        : null;
  }

  int _floor(int tUs) {
    var lo = 0, hi = cues.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start.inMicroseconds <= tUs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}
