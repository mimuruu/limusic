// Tests for the pieces of this app that carry logic rather than layout: the API client's models,
// the duration formatter, and the pairing screen's address parsing.
//
// The remote itself is a thin shell over the desktop API, so there is no fake server here: the
// interesting failures (wrong address, unpaired token, unreachable desktop) are covered by the
// Rust side's own tests and by exercising the real app, not by mocking HTTP.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:limusic_remote/api.dart';
import 'package:limusic_remote/main.dart';

void main() {
  group('fmtTime', () {
    test('formats whole minutes and seconds', () {
      expect(fmtTime(0), '0:00');
      expect(fmtTime(5), '0:05');
      expect(fmtTime(65), '1:05');
      expect(fmtTime(213.58), '3:33');
      expect(fmtTime(600), '10:00');
    });

    test('never renders a negative or unset duration as garbage', () {
      expect(fmtTime(-1), '0:00');
      expect(fmtTime(double.nan), '0:00');
    });
  });

  group('Song', () {
    test('reads the desktop snake_case shape', () {
      final s = Song({
        'video_id': 'abc',
        'title': 'Title',
        'artists': 'Artist',
        'album': 'Album',
        'thumbnail': 'https://example/x.jpg',
        'duration': '3:34',
      });
      expect(s.videoId, 'abc');
      expect(s.title, 'Title');
      expect(s.artists, 'Artist');
      expect(s.album, 'Album');
      expect(s.duration, '3:34');
    });

    test('reads the camelCase shape the now-playing object uses', () {
      // The desktop's now-playing object is hand-built camelCase (`videoId`) while queue rows are
      // snake_case. Both must yield the same field, or the Playing tab silently loses the id.
      final s = Song({'videoId': 'xyz', 'title': 'T', 'artists': 'A'});
      expect(s.videoId, 'xyz');
    });

    test('keeps the raw row so /api/play can send it back verbatim', () {
      final raw = {'video_id': 'abc', 'title': 'T', 'autoplay': true, 'queued': true};
      expect(Song(raw).raw, same(raw));
    });

    test('survives a row with missing fields', () {
      final s = Song(const {});
      expect(s.videoId, '');
      expect(s.title, '');
      expect(s.album, isNull);
    });
  });

  group('NowPlaying', () {
    test('parses a playing response', () {
      final n = NowPlaying.fromJson({
        'now': {'video_id': 'x', 'title': 'T', 'artists': 'A'},
        'paused': false,
        'position': 8.5,
        'duration': 213.581,
        'volume': 33,
        'queueLength': [1, 2, 3],
        'shuffle': true,
        'repeat': 'all',
      });
      expect(n.song?.title, 'T');
      expect(n.paused, isFalse);
      expect(n.position, 8.5);
      expect(n.volume, 33);
      expect(n.queueLength, 3);
      expect(n.shuffle, isTrue);
      expect(n.repeat, 'all');
    });

    test('handles an idle desktop (now: null) without throwing', () {
      final n = NowPlaying.fromJson({'now': null, 'paused': true, 'volume': 100});
      expect(n.song, isNull);
      expect(n.position, 0);
      expect(n.duration, 0);
    });
  });

  group('QueueState', () {
    test('parses items and the playing index', () {
      final q = QueueState.fromJson({
        'items': [
          {'video_id': 'a', 'title': 'One', 'artists': 'X'},
          {'video_id': 'b', 'title': 'Two', 'artists': 'Y'},
        ],
        'currentIndex': 1,
        'shuffle': false,
        'repeat': 'off',
      });
      expect(q.items.length, 2);
      expect(q.currentIndex, 1);
      expect(q.items[1].title, 'Two');
    });

    test('an empty queue is not an error', () {
      final q = QueueState.fromJson({'items': <dynamic>[], 'currentIndex': 0});
      expect(q.items, isEmpty);
    });

    test('the playing row is the item at currentIndex, not the first item', () {
      // The Queue tab highlights `items[currentIndex]`. The desktop advances `currentIndex` on a
      // skip while the list length can stay the same (playing an existing queue row) — which is
      // exactly the case that used to leave the highlight on the previous track.
      final q = QueueState.fromJson({
        'items': [
          {'video_id': 'a', 'title': 'One', 'artists': 'X'},
          {'video_id': 'b', 'title': 'Two', 'artists': 'Y'},
          {'video_id': 'c', 'title': 'Three', 'artists': 'Z'},
        ],
        'currentIndex': 2,
      });
      expect(q.items[q.currentIndex].videoId, 'c');
      expect(q.items.first.videoId, isNot(q.items[q.currentIndex].videoId));
    });

    test('a currentIndex past the end does not throw', () {
      // A queue can shrink under a stale index between the status poll and the queue poll. Reading
      // the row must not crash the list.
      final q = QueueState.fromJson({
        'items': [
          {'video_id': 'a', 'title': 'One', 'artists': 'X'},
        ],
        'currentIndex': 5,
      });
      expect(q.currentIndex, 5);
      expect(q.items.length, 1);
    });
  });

  group('PairScreen', () {
    testWidgets('asks for an address before showing the code field', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PairScreen(onPaired: (_, _) async {}),
      ));
      // Nothing to pair against until an address is verified, so no code field yet.
      expect(find.text('Check connection'), findsOneWidget);
      expect(find.text('Pairing code'), findsNothing);
      expect(find.text('Limusic Remote'), findsOneWidget);
    });

    testWidgets('explains what to do when the address is empty', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PairScreen(onPaired: (_, _) async {}),
      ));
      await tester.tap(find.text('Check connection'));
      await tester.pump();
      expect(find.textContaining('Enter the address'), findsOneWidget);
    });
  });
}
