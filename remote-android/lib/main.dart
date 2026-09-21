import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'store.dart';

void main() => runApp(const LimusicRemoteApp());

/// The desktop's accent, so the phone and the app it drives look like one product.
const _seed = Color(0xFFE54866);

class LimusicRemoteApp extends StatelessWidget {
  const LimusicRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Limusic Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const Root(),
    );
  }
}

/// Decides between the pairing screen and the remote, and owns the session: when the desktop stops
/// accepting our token, every screen below is torn down and pairing starts again.
class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool _loading = true;
  LimusicApi? _api;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final saved = await Store.load();
    if (saved.url != null && saved.token != null) {
      setState(() {
        _api = LimusicApi(saved.url!, token: saved.token);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _onPaired(String url, String token) async {
    await Store.save(url, token);
    setState(() => _api = LimusicApi(url, token: token));
  }

  /// The desktop dropped us: forget the dead token and go back to pairing.
  Future<void> _onUnpaired() async {
    await Store.clear();
    setState(() => _api = null);
  }

  Future<void> _disconnect() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
            'This phone will forget the server. You can pair again with a new code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (sure == true) await _onUnpaired();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final api = _api;
    return api == null
        ? PairScreen(onPaired: _onPaired)
        : RemoteScreen(api: api, onUnpaired: _onUnpaired, onDisconnect: _disconnect);
  }
}

// --- pairing ---------------------------------------------------------------------------------

/// Connect screen: address in, then the 6-digit code the desktop is showing.
class PairScreen extends StatefulWidget {
  final Future<void> Function(String url, String token) onPaired;
  const PairScreen({super.key, required this.onPaired});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _url = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'My phone');
  bool _busy = false;
  String? _error;
  bool _reachable = false;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Normalise what the user typed into a base URL. People paste `192.168.1.5:4317`, with or
  /// without a scheme, and getting that wrong should not be an error dialog.
  String? _normalise(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  Future<void> _check() async {
    final base = _normalise(_url.text);
    if (base == null) {
      setState(() => _error = 'Enter the address shown in Limusic, e.g. 192.168.1.5:4317');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await LimusicApi.ping(base);
      setState(() {
        _reachable = true;
        _url.text = base;
      });
    } catch (e) {
      setState(() {
        _reachable = false;
        _error = '$e\n\nCheck that the remote is on in Limusic and that both devices are on the '
            'same WiFi.';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    final base = _normalise(_url.text);
    if (base == null || _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter the address and the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await LimusicApi.pair(base, _code.text.trim(), _name.text.trim());
      await widget.onPaired(base, token);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.speaker_group, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Limusic Remote',
                      textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'In Limusic on your computer, open Settings, Phone remote. Turn it on, then '
                    'press "New code".',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: '192.168.1.5:4317',
                      prefixIcon: Icon(Icons.lan),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (_reachable) setState(() => _reachable = false);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (!_reachable)
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _check,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Check connection'),
                    )
                  else ...[
                    Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('Found Limusic', style: theme.textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'This phoneâ€™s name',
                        prefixIcon: Icon(Icons.smartphone),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      style: const TextStyle(fontSize: 22, letterSpacing: 8),
                      decoration: const InputDecoration(
                        labelText: 'Pairing code',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _pair,
                      icon: const Icon(Icons.link),
                      label: const Text('Pair'),
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(_error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- remote ----------------------------------------------------------------------------------

/// The remote itself: now playing, transport, volume, queue and search.
class RemoteScreen extends StatefulWidget {
  final LimusicApi api;
  final Future<void> Function() onUnpaired;
  final Future<void> Function() onDisconnect;
  const RemoteScreen({
    super.key,
    required this.api,
    required this.onUnpaired,
    required this.onDisconnect,
  });

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  NowPlaying? _status;
  Timer? _poll;
  String? _error;

  /// While the user drags the seek bar, polling must not fight their thumb. The value here is the
  /// one shown until the drag ends and the seek is sent.
  double? _scrubTarget;

  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _tick();
    // 1s keeps the progress bar honest without hammering the desktop; a LAN round trip is
    // sub-millisecond, so this is cheap. `Timer.periodic` also means a slow response cannot stack
    // up requests: the next tick is skipped while one is in flight, see `_inFlight`.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  bool _inFlight = false;

  Future<void> _tick() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final s = await widget.api.status();
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.needsPairing) {
        _poll?.cancel();
        await widget.onUnpaired();
        return;
      }
      setState(() => _error = e.message);
    } catch (e) {
      // A dropped WiFi connection is the ordinary case here, so it surfaces as a quiet banner and
      // the next tick clears it once the network is back.
      if (!mounted) return;
      setState(() => _error = 'Cannot reach the desktop. Is Limusic still running?');
    } finally {
      _inFlight = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Run a command, then refresh immediately so the UI does not wait out a poll interval.
  ///
  /// Every failure here is expected at least once (a revoked token, the desktop quitting mid-tap),
  /// so it is reported rather than thrown.
  Future<void> _do(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.needsPairing) {
        _poll?.cancel();
        await widget.onUnpaired();
        return;
      }
      _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Command failed. Check the connection.');
    }
    // Skipping a track is not finished when the HTTP call returns: the desktop then hydrates the
    // queue (a radio continuation is a YouTube round trip) and only afterwards does its snapshot
    // show the new track and the grown queue. Reading immediately caught the pre-hydration state,
    // which is why the Queue tab kept showing the previous track until a manual refresh. One short
    // settle, then read.
    await Future.delayed(const Duration(milliseconds: 400));
    await _tick();
    // The queue can still be growing when a radio is being fetched, so give it a second look; the
    // Queue tab's `didUpdateWidget` does the actual reload when it sees the change land.
    await Future.delayed(const Duration(milliseconds: 700));
    await _tick();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Limusic'),
        actions: [
          IconButton(
            tooltip: 'Disconnect',
            onPressed: widget.onDisconnect,
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 12)),
            ),
          Expanded(
            child: s == null
                ? const Center(child: CircularProgressIndicator())
                : IndexedStack(
                    index: _tab,
                    children: [
                      _NowPlayingView(
                        api: widget.api,
                        status: s,
                        scrubTarget: _scrubTarget,
                        onScrub: (v) => setState(() => _scrubTarget = v),
                        onScrubEnd: (v) async {
                          // Hold the thumb where the user dropped it until the desktop confirms
                          // the seek. Clearing it first let the next poll (up to a second away)
                          // paint the pre-seek position, which is the visible jump.
                          await _do(() => widget.api.seek(v));
                          if (mounted) setState(() => _scrubTarget = null);
                        },
                        onTransport: _do,
                      ),
                      _QueueView(api: widget.api, status: s, doAction: _do, tab: _tab),
                      _LyricsView(api: widget.api, status: s, tab: _tab),
                      _SearchView(api: widget.api, doAction: _do),
                    ],
                  ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Playing'),
          NavigationDestination(icon: Icon(Icons.queue_music), label: 'Queue'),
          NavigationDestination(icon: Icon(Icons.lyrics_outlined), label: 'Lyrics'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        ],
      ),
    );
  }
}

/// The "Playing" tab: artwork, title, scrubber, transport and volume.
class _NowPlayingView extends StatelessWidget {
  final LimusicApi api;
  final NowPlaying status;
  final double? scrubTarget;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onScrubEnd;
  final Future<void> Function(Future<void> Function()) onTransport;

  const _NowPlayingView({
    required this.api,
    required this.status,
    required this.scrubTarget,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onTransport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final song = status.song;
    if (song == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Nothing is playing on the desktop yet.\nSearch for something.',
              textAlign: TextAlign.center),
        ),
      );
    }

    // The duration the desktop reports can lag the track by a moment, so never let the shown
    // position exceed it.
    final max = status.duration > 0 ? status.duration : 1.0;
    final pos = (scrubTarget ?? status.position).clamp(0.0, max).toDouble();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: song.thumbnail == null
                ? Container(
                    width: 260,
                    height: 260,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note, size: 72),
                  )
                : Image.network(
                    song.thumbnail!,
                    width: 260,
                    height: 260,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 260,
                      height: 260,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.music_note, size: 72),
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          Text(song.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(song.artists,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Slider(
            value: pos,
            max: max,
            onChanged: onScrub,
            onChangeEnd: onScrubEnd,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmtTime(pos), style: theme.textTheme.bodySmall),
                Text(fmtTime(status.duration), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 32,
                tooltip: 'Toggle shuffle',
                onPressed: () => onTransport(api.shuffle),
                // One icon for both states, distinguished by colour. `Icons.shuffle_on` is a
                // real icon but is referenced only inside a ternary, which the build's icon
                // tree-shaker does not always see, and it shipped as a blank box.
                icon: const Icon(Icons.shuffle),
                color: status.shuffle ? theme.colorScheme.primary : null,
              ),
              const SizedBox(width: 8),
              IconButton(
                iconSize: 44,
                tooltip: 'Previous',
                onPressed: () => onTransport(api.previous),
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                iconSize: 48,
                tooltip: status.paused ? 'Play' : 'Pause',
                // The explicit target state, not a blind toggle: a retried tap cannot end up
                // flipping twice.
                onPressed: () => onTransport(() => api.setPlaying(status.paused)),
                icon: Icon(status.paused ? Icons.play_arrow : Icons.pause),
              ),
              const SizedBox(width: 8),
              IconButton(
                iconSize: 44,
                tooltip: 'Next',
                onPressed: () => onTransport(api.next),
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: 8),
              IconButton(
                iconSize: 32,
                tooltip: 'Repeat: off, all, one',
                onPressed: () => onTransport(() => api.setRepeat(_nextRepeat(status.repeat))),
                icon: Icon(_repeatIcon(status.repeat)),
                color: status.repeat == 'off' ? null : theme.colorScheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _VolumeRow(api: api, volume: status.volume, onTransport: onTransport),
        ],
      ),
    );
  }

  static IconData _repeatIcon(String mode) =>
      mode == 'one' ? Icons.repeat_one : Icons.repeat;

  /// Cycle off â†’ all â†’ one, matching what the desktop's own button does.
  static String _nextRepeat(String mode) => switch (mode) {
        'off' => 'all',
        'all' => 'one',
        _ => 'off',
      };
}

/// Volume slider. Stateful so the thumb follows the finger: the desktop's value arrives once a
/// second, and binding the slider straight to it would snap it back mid-drag. Only the settled
/// value is sent, which is also why `/api/volume` persists it.
class _VolumeRow extends StatefulWidget {
  final LimusicApi api;
  final int volume;
  final Future<void> Function(Future<void> Function()) onTransport;
  const _VolumeRow({required this.api, required this.volume, required this.onTransport});

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = (_drag ?? widget.volume.toDouble()).clamp(0.0, 100.0).toDouble();
    return Row(
      children: [
        Icon(
          value == 0 ? Icons.volume_off : Icons.volume_down,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        Expanded(
          child: Slider(
            value: value,
            max: 100,
            divisions: 100,
            label: '${value.round()}%',
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) async {
              // Same reasoning as the seek bar: hold the thumb where the user left it until the
              // desktop reports the new level. Clearing first let the next poll paint the old
              // value, which is the visible jump back.
              await widget.onTransport(() => widget.api.setVolume(v.round()));
              if (mounted) setState(() => _drag = null);
            },
          ),
        ),
        Icon(Icons.volume_up, color: theme.colorScheme.onSurfaceVariant),
      ],
    );
  }
}

/// The "Queue" tab: what is next, tap to jump, swipe to remove.
class _QueueView extends StatefulWidget {
  final LimusicApi api;
  final NowPlaying status;
  final Future<void> Function(Future<void> Function()) doAction;
  final int tab;
  const _QueueView({
    required this.api,
    required this.status,
    required this.doAction,
    required this.tab,
  });

  @override
  State<_QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<_QueueView> {
  QueueState? _queue;

  /// Own poll, running only while this tab is the visible one.
  ///
  /// `didUpdateWidget` alone was not enough. The status snapshot it compares against is fetched by
  /// the parent, and the queue it drives is a *separate* request — so the row highlight could be
  /// painted from a queue response that predated the track change, with nothing later to correct
  /// it. Watching the queue on its own timer removes that dependency: whatever the queue endpoint
  /// currently says is what the list shows, one way or another, within a second.
  Timer? _poll;

  /// Set while a `/api/queue` request is in flight, so a slow response cannot stack requests.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _syncPoll();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QueueView old) {
    super.didUpdateWidget(old);
    // Start or stop the timer as the tab becomes visible or hidden. The other tabs are built too
    // (IndexedStack keeps them alive), and polling the queue behind the user's back would be waste.
    if (old.tab != widget.tab) _syncPoll();
    // A track change still triggers an immediate read, so a skip feels instant rather than waiting
    // out the interval. `queueLength` is included because a radio continuation grows the list
    // without changing the playing track.
    final prev = old.status.song?.videoId;
    final next = widget.status.song?.videoId;
    if (widget.tab == 1 &&
        (prev != next || old.status.queueLength != widget.status.queueLength)) {
      _load();
    }
  }

  /// Run the queue poll only while this tab is on screen.
  void _syncPoll() {
    _poll?.cancel();
    if (widget.tab != 1) {
      _poll = null;
      return;
    }
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final q = await widget.api.queue();
      if (mounted) setState(() => _queue = q);
    } catch (_) {
      // The status banner already reports an unreachable desktop.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _queue;
    if (q == null) return const Center(child: CircularProgressIndicator());
    if (q.items.isEmpty) {
      return const Center(child: Text('The queue is empty.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: q.items.length,
        itemBuilder: (context, i) {
          final song = q.items[i];
          final playing = i == q.currentIndex;
          final theme = Theme.of(context);
          return Dismissible(
            key: ValueKey('${song.videoId}-$i'),
            direction: DismissDirection.endToStart,
            // The desktop refuses to remove the track that is playing (state.rs skips
            // `index == current`). Blocking the swipe up front is what keeps the list honest:
            // letting it through would drop the row here while the song kept playing there, and
            // since `doAction` swallows its error into a snackbar, nothing would put it back.
            confirmDismiss: (_) async {
              if (playing) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                      content: Text('That track is playing. Skip it first, then remove it.'),
                      duration: Duration(seconds: 2)));
                return false;
              }
              return true;
            },
            background: Container(
              color: theme.colorScheme.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
            ),
            // The index sent is the row's position in `q.items`, which is only meaningful if the
            // list on screen still matches the desktop's. It is re-read first for that reason: a
            // track change while this list sat on screen would have shifted every index under it,
            // and removing `i` would then delete the wrong song. `_load` runs before the delete so
            // the check and the removal agree.
            onDismissed: (_) async {
              await _load();
              final fresh = _queue;
              if (fresh == null || i >= fresh.items.length) return;
              // Re-resolve by identity: find the row that is still this song.
              final at = fresh.items.indexWhere((s) => s.videoId == song.videoId);
              if (at < 0) return; // already gone from the desktop's queue
              await widget.doAction(() => widget.api.removeFromQueue(at));
              await _load();
            },
            child: ListTile(
              leading: song.thumbnail == null
                  ? const Icon(Icons.music_note)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(song.thumbnail!,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(Icons.music_note)),
                    ),
              title: Text(song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: playing ? theme.colorScheme.primary : null,
                      fontWeight: playing ? FontWeight.w600 : null)),
              subtitle: Text(song.artists, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: playing ? const Icon(Icons.equalizer) : Text(song.duration ?? ''),
              onTap: () => widget.doAction(() => widget.api.playIndex(i)),
            ),
          );
        },
      ),
    );
  }
}

/// The "Lyrics" tab: the desktop's lyrics, following the song.
///
/// The desktop already resolves lyrics from its provider chain and caches them, so this asks it
/// (`/api/lyrics`) rather than talking to LRCLIB or Boidu itself. That keeps one source of truth
/// and means the phone shows exactly what the app's own panel would.
class _LyricsView extends StatefulWidget {
  final LimusicApi api;
  final NowPlaying status;
  final int tab;
  const _LyricsView({required this.api, required this.status, required this.tab});

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final _scroll = ScrollController();

  /// The track these lyrics belong to, so a poll that reports the same song does not refetch.
  String? _loadedFor;
  Lyrics? _lyrics;
  bool _loading = false;

  /// True when the desktop answered "nobody has lyrics for this", which is not the same as "not
  /// loaded yet" and should say so.
  bool _none = false;

  String? _error;

  /// A key per lyric line, so the active one can be brought into view with `ensureVisible`.
  ///
  /// Offsets were the first attempt and they do not work here: a row can report its global screen
  /// position, but that is not a scroll offset, and the two diverge as soon as the list is not at
  /// the top. `ensureVisible` asks the scrollable itself, which is right by construction.
  final _lineKeys = <int, GlobalKey>{};

  /// The line that was last scrolled to, so the view follows the song once per line instead of
  /// fighting the user's own scrolling.
  int _lastScrolled = -1;

  /// True while the user is dragging, so auto-scroll backs off until they let go.
  bool _userScrolling = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // A drag or a fling means the user is reading something else; stop chasing the song until
      // they settle (the notifier clears once the scroll activity finishes).
      _userScrolling = _scroll.position.isScrollingNotifier.value;
    });
    if (widget.tab == 2) _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LyricsView old) {
    super.didUpdateWidget(old);
    if (widget.tab != 2) return;
    final id = widget.status.song?.videoId;
    if (id != null && id != _loadedFor) {
      // A new track: start over, so the previous song's lyrics never show under the new title.
      _loadedFor = id;
      _lyrics = null;
      _none = false;
      _lineKeys.clear();
      _lastScrolled = -1;
      _load();
    }
  }

  Future<void> _load() async {
    final song = widget.status.song;
    if (song == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await widget.api.lyrics();
      if (!mounted) return;
      setState(() {
        _lyrics = l;
        _none = l == null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load lyrics.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Bring the active line into view, once per line, unless the user is scrolling.
  void _followActive(int active) {
    if (_userScrolling || active < 0 || active == _lastScrolled) return;
    final key = _lineKeys[active];
    final ctx = key?.currentContext;
    if (ctx == null) return; // not built yet (off screen); the next tick will catch it
    _lastScrolled = active;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      // Land the line a third of the way down rather than at the very top, which leaves the
      // upcoming lyrics visible where a reader expects them.
      alignment: 0.33,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.status.song == null) {
      return const Center(child: Text('Nothing is playing.'));
    }
    if (_loading && _lyrics == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    final l = _lyrics;
    if (l == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _none ? 'No lyrics found for this track.' : 'No lyrics.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (l.instrumental) {
      return const Center(child: Text('This track is instrumental.'));
    }

    // The desktop's position is what the highlight follows. It updates once a second, so the active
    // line lands within a second of the audio — fine for reading along.
    final pos = widget.status.position;
    final active = l.synced ? l.lineAt(pos) : -1;
    if (l.synced) {
      // After this frame, the row for `active` will have reported its offset.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followActive(active);
      });
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            itemCount: l.lines.length,
            itemBuilder: (context, i) {
              final line = l.lines[i];
              final isActive = i == active;
              return _LyricRow(
                key: _lineKeys.putIfAbsent(i, () => GlobalKey()),
                line: line,
                active: isActive,
                position: pos,
                synced: l.synced,
              );
            },
          ),
        ),
        // Attribution, same idea as the desktop's panel footer: these lyrics are not ours.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Text(
            l.source.isEmpty ? 'Lyrics' : 'Lyrics from ${l.source}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// One lyric line. Highlights the words already sung when the line carries per-word timings, and
/// falls back to styling the whole line when it does not.
///
/// Keyed by the parent so the active line can be scrolled into view.
class _LyricRow extends StatelessWidget {
  final LyricLine line;
  final bool active;
  final double position;
  final bool synced;

  const _LyricRow({
    super.key,
    required this.line,
    required this.active,
    required this.position,
    required this.synced,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.titleMedium;
    final activeStyle = base?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    // Unsynced lyrics have no timeline to follow, so every line reads the same.
    final idleStyle = base?.copyWith(
      color: synced ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface,
    );

    final sung = active ? line.wordsSung(position) : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Builder(
        builder: (context) {
          final words = line.words;
          final child = (words == null || words.isEmpty)
              ? Text(line.text, style: active ? activeStyle : idleStyle)
              : RichText(
                  text: TextSpan(
                    style: active ? activeStyle : idleStyle,
                    children: [
                      for (var w = 0; w < words.length; w++)
                        TextSpan(
                          text: words[w].text,
                          style: (w < sung)
                              ? TextStyle(color: theme.colorScheme.primary)
                              : null,
                        ),
                    ],
                  ),
                );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              child,
              if (line.translation != null && active)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    line.translation!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The "Search" tab: type, then tap a result to play it on the desktop.
class _SearchView extends StatefulWidget {
  final LimusicApi api;
  final Future<void> Function(Future<void> Function()) doAction;
  const _SearchView({required this.api, required this.doAction});

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Song>? _results;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Debounced so typing a word is one request, not one per letter. The desktop's search is a
  /// YouTube round trip, and every keystroke would be a new one.
  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(v.trim()));
  }

  Future<void> _search(String query) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.search(query);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            decoration: const InputDecoration(
              hintText: 'Search YouTube Music',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        Expanded(
          child: _results == null
              ? const Center(child: Text('Search for a song, then tap it to play.'))
              : ListView.builder(
                  itemCount: _results!.length,
                  itemBuilder: (context, i) {
                    final song = _results![i];
                    return ListTile(
                      leading: song.thumbnail == null
                          ? const Icon(Icons.music_note)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.network(song.thumbnail!,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Icon(Icons.music_note)),
                            ),
                      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(song.artists, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(song.duration ?? ''),
                      onTap: () async {
                        await widget.doAction(() => widget.api.play(song));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Playing ${song.title}'),
                                duration: const Duration(seconds: 2)),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
