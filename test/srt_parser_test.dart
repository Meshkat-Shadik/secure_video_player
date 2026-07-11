import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

void main() {
  group('parseSrt', () {
    test('parses a basic cue', () {
      final cues = parseSrt('1\n'
          '00:00:01,000 --> 00:00:04,000\n'
          'Hello world\n');
      expect(cues, hasLength(1));
      expect(cues.first.index, 1);
      expect(cues.first.start, const Duration(seconds: 1));
      expect(cues.first.end, const Duration(seconds: 4));
      expect(cues.first.text, 'Hello world');
    });

    test('strips a BOM and handles CRLF line endings', () {
      final cues = parseSrt('﻿1\r\n'
          '00:00:00,500 --> 00:00:02,000\r\n'
          'Line one\r\nLine two\r\n');
      expect(cues, hasLength(1));
      expect(cues.first.start, const Duration(milliseconds: 500));
      expect(cues.first.text, 'Line one\nLine two');
    });

    test('parses multiple cues separated by blank lines', () {
      final cues = parseSrt('1\n'
          '00:00:01,000 --> 00:00:02,000\n'
          'First\n\n'
          '2\n'
          '00:00:03,000 --> 00:00:04,000\n'
          'Second\n');
      expect(cues.map((c) => c.text), ['First', 'Second']);
      expect(cues.map((c) => c.index), [1, 2]);
    });

    test('preserves inline tags in text, plainText strips them', () {
      final cues = parseSrt('1\n'
          '00:00:01,000 --> 00:00:02,000\n'
          '<i>Whispered</i> <b>loud</b>\n');
      expect(cues.first.text, '<i>Whispered</i> <b>loud</b>');
      expect(cues.first.plainText, 'Whispered loud');
    });

    test('accepts a dot millisecond separator', () {
      final cues = parseSrt('1\n'
          '00:00:01.250 --> 00:00:02.500\n'
          'x\n');
      expect(cues.first.start, const Duration(milliseconds: 1250));
      expect(cues.first.end, const Duration(milliseconds: 2500));
    });

    test('tolerates a missing cue number', () {
      final cues = parseSrt('00:00:01,000 --> 00:00:02,000\n'
          'No number\n');
      expect(cues, hasLength(1));
      expect(cues.first.index, 1); // auto-assigned
      expect(cues.first.text, 'No number');
    });

    test('skips a malformed block without aborting the file', () {
      final cues = parseSrt('1\n'
          'this is not a timecode\n'
          'garbage\n\n'
          '2\n'
          '00:00:05,000 --> 00:00:06,000\n'
          'Good cue\n');
      expect(cues, hasLength(1));
      expect(cues.first.text, 'Good cue');
    });

    test('sorts out-of-order cues by start time', () {
      final cues = parseSrt('1\n'
          '00:00:10,000 --> 00:00:11,000\n'
          'Later\n\n'
          '2\n'
          '00:00:01,000 --> 00:00:02,000\n'
          'Earlier\n');
      expect(cues.map((c) => c.text), ['Earlier', 'Later']);
    });

    test('returns an unmodifiable list', () {
      final cues = parseSrt('');
      expect(cues, isEmpty);
      expect(
          () => cues.add(const SubtitleCue(
              index: 0,
              start: Duration.zero,
              end: Duration.zero,
              text: '')),
          throwsUnsupportedError);
    });
  });

  group('SubtitleCueLookup', () {
    final cues = parseSrt('1\n00:00:01,000 --> 00:00:02,000\nA\n\n'
        '2\n00:00:03,000 --> 00:00:04,000\nB\n\n'
        '3\n00:00:05,000 --> 00:00:06,000\nC\n');

    test('finds the active cue and gaps return null', () {
      final look = SubtitleCueLookup(cues);
      expect(look.at(const Duration(milliseconds: 1500))?.text, 'A');
      expect(look.at(const Duration(milliseconds: 2500)), isNull); // gap
      expect(look.at(const Duration(milliseconds: 3500))?.text, 'B');
      expect(look.at(const Duration(milliseconds: 5500))?.text, 'C');
    });

    test('before-first and after-last return null', () {
      final look = SubtitleCueLookup(cues);
      expect(look.at(Duration.zero), isNull);
      expect(look.at(const Duration(seconds: 30)), isNull);
    });

    test('correct across forward and backward seeks', () {
      final look = SubtitleCueLookup(cues);
      // steady forward
      expect(look.at(const Duration(milliseconds: 1500))?.text, 'A');
      // big jump forward
      expect(look.at(const Duration(milliseconds: 5500))?.text, 'C');
      // jump back
      expect(look.at(const Duration(milliseconds: 1500))?.text, 'A');
      // single step back into a gap
      expect(look.at(const Duration(milliseconds: 500)), isNull);
      // and forward again
      expect(look.at(const Duration(milliseconds: 3500))?.text, 'B');
    });

    test('end boundary is exclusive, start inclusive', () {
      final look = SubtitleCueLookup(cues);
      expect(look.at(const Duration(seconds: 1))?.text, 'A'); // inclusive start
      expect(look.at(const Duration(seconds: 2)), isNull); // exclusive end
    });

    test('empty cue list never throws', () {
      final look = SubtitleCueLookup(const []);
      expect(look.at(const Duration(seconds: 1)), isNull);
    });
  });
}
