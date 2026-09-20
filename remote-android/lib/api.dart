import 'dart:convert';

import 'package:http/http.dart' as http;

/// One entry of the desktop's queue / a search result. Mirrors the JSON the Rust side serializes;
/// unknown fields are ignored so the desktop can add more without breaking this app.
///
/// The desktop uses two spellings for the same data: queue and search items are a `SongItem`
/// serialized with snake_case (`video_id`), while the now-playing object is hand-built as camelCase
/// (`videoId`). Both are read here, so the app does not depend on which one it was handed.
class Song {
  final String videoId;
  final String title;
  final String artists;
  final String? album;
  final String? thumbnail;
  final String? duration;

  /// The whole row as the desktop sent it. `/api/play` takes a `SongItem` back verbatim, and the
  /// queued/autoplay flags it carries are queue metadata this app has no business reconstructing.
  final Map<String, dynamic> raw;

  Song(this.raw)
      : videoId = (raw['video_id'] ?? raw['videoId']) as String? ?? '',
        title = raw['title'] as String? ?? '',
        artists = raw['artists'] as String? ?? '',
        album = raw['album'] as String?,
        thumbnail = raw['thumbnail'] as String?,
        duration = raw['duration'] as String?;

  static List<Song> listFrom(dynamic items) =>
      (items as List<dynamic>? ?? const []).map((e) => Song(e as Map<String, dynamic>)).toList();
}

/// What `/api/status` reports: the current track plus transport state.
class NowPlaying {
  final Song? song;
  final bool paused;
  final double position;
  final double duration;
  final int volume;
  final int queueLength;
  final bool shuffle;
  final String repeat;

  NowPlaying({
    required this.song,
    required this.paused,
    required this.position,
    required this.duration,
    required this.volume,
    required this.queueLength,
    required this.shuffle,
    required this.repeat,
  });

  factory NowPlaying.fromJson(Map<String, dynamic> j) {
    final now = j['now'];
    return NowPlaying(
      song: now is Map<String, dynamic> ? Song(now) : null,
      paused: j['paused'] as bool? ?? true,
      position: (j['position'] as num?)?.toDouble() ?? 0,
      duration: (j['duration'] as num?)?.toDouble() ?? 0,
      volume: (j['volume'] as num?)?.toInt() ?? 100,
      queueLength: (j['queueLength'] as List<dynamic>?)?.length ?? 0,
      shuffle: j['shuffle'] as bool? ?? false,
      repeat: j['repeat'] as String? ?? 'off',
    );
  }
}

/// The queue as `/api/queue` reports it.
class QueueState {
  final List<Song> items;
  final int currentIndex;
  final bool shuffle;
  final String repeat;
  const QueueState({
    required this.items,
    required this.currentIndex,
    required this.shuffle,
    required this.repeat,
  });

  factory QueueState.fromJson(Map<String, dynamic> j) => QueueState(
        items: Song.listFrom(j['items']),
        currentIndex: (j['currentIndex'] as num?)?.toInt() ?? 0,
        shuffle: j['shuffle'] as bool? ?? false,
        repeat: j['repeat'] as String? ?? 'off',
      );
}

/// A failure the UI can show. `needsPairing` distinguishes "this device is not paired any more"
/// (which sends the user back to the pair screen) from an ordinary error worth a snackbar.
class ApiException implements Exception {
  final String message;
  final bool needsPairing;
  ApiException(this.message, {this.needsPairing = false});
  @override
  String toString() => message;
}

/// Client for the Limusic phone-remote API (`src-tauri/src/remote.rs`).
class LimusicApi {
  /// Base URL without a trailing slash, e.g. `http://192.168.1.5:4317`.
  final String baseUrl;

  /// Device token from pairing. Sent on every authenticated request.
  final String? token;

  LimusicApi(this.baseUrl, {this.token});

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null && token!.isNotEmpty) 'x-limusic-token': token!,
      };

  /// A short timeout: everything here is a LAN round trip, and a hung request would leave the UI
  /// spinning through a whole polling interval.
  static const _timeout = Duration(seconds: 8);

  Future<Map<String, dynamic>> _decode(http.Response r) async {
    if (r.statusCode == 401) {
      throw ApiException('This phone is no longer paired.', needsPairing: true);
    }
    final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) {
      throw ApiException(body['error'] as String? ?? 'HTTP ${r.statusCode}');
    }
    return body;
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    final r = await http
        .post(_uri(path), headers: _headers, body: body == null ? null : jsonEncode(body))
        .timeout(_timeout);
    return _decode(r);
  }

  /// Unauthenticated probe, used by the connect screen to tell "wrong address" from "not paired".
  static Future<Map<String, dynamic>> ping(String baseUrl) async {
    final r = await http.get(Uri.parse('$baseUrl/api/ping')).timeout(_timeout);
    if (r.statusCode != 200) throw ApiException('Not a Limusic remote (HTTP ${r.statusCode})');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Trade the on-screen code for a device token. `name` is what the desktop lists this phone as.
  static Future<String> pair(String baseUrl, String code, String name) async {
    final r = await http
        .post(Uri.parse('$baseUrl/api/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'name': name}))
        .timeout(_timeout);
    final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw ApiException(body['error'] as String? ?? 'Pairing failed (HTTP ${r.statusCode})');
    }
    return body['token'] as String;
  }

  Future<NowPlaying> status() async => NowPlaying.fromJson(await _decode(
      await http.get(_uri('/api/status'), headers: _headers).timeout(_timeout)));

  Future<QueueState> queue() async => QueueState.fromJson(await _decode(
      await http.get(_uri('/api/queue'), headers: _headers).timeout(_timeout)));

  Future<List<Song>> search(String query) async {
    final body = await _decode(await http
        .get(_uri('/api/search', {'q': query}), headers: _headers)
        .timeout(_timeout));
    return Song.listFrom(body['items']);
  }

  Future<void> toggle() => _post('/api/toggle');

  /// Explicit desired state, so a retried call cannot double-toggle.
  Future<void> setPlaying(bool playing) => _post('/api/play-pause', {'playing': playing});

  Future<void> next() => _post('/api/next');
  Future<void> previous() => _post('/api/previous');
  Future<void> seek(double seconds) => _post('/api/seek', {'position': seconds});
  Future<void> setVolume(int volume) => _post('/api/volume', {'volume': volume});
  Future<void> playIndex(int index) => _post('/api/play-index', {'index': index});
  Future<void> removeFromQueue(int index) => _post('/api/remove-from-queue', {'index': index});
  Future<void> shuffle() => _post('/api/shuffle');
  Future<void> setRepeat(String mode) => _post('/api/repeat', {'mode': mode});

  /// Play a track. The whole `SongItem` goes back, so the desktop can seed its queue without a
  /// second round trip.
  Future<void> play(Song song) => _post('/api/play', song.raw);
}

/// Human-readable clock for a duration in seconds.
String fmtTime(double seconds) {
  if (seconds.isNaN || seconds < 0) return '0:00';
  final total = seconds.floor();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
