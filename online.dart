// Xăm hường - simple online play through a Firebase Realtime Database.
//
// The host's phone runs the game. Other players send a "roll" request, the host
// rolls and writes a snapshot, and every phone plays the same animation from it.
// Every phone writes a small "I'm here" beat; the host turns players who have
// been quiet for 5 minutes (or who left) into bots, and the players cancel the
// game when the host has been quiet for 10 minutes.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'chat.dart';
import 'online_config.dart';
import 'widgets.dart';
import 'xam_huong_engine.dart';
import 'xam_huong_game.dart';

const int maxOnlinePlayers = 4;
const Duration beatEvery = Duration(seconds: 8);
const Duration lobbyQuietLimit = Duration(seconds: 30); // host hides ghosts
const Duration playerAwayLimit = Duration(minutes: 5); // then becomes a bot
const Duration hostAwayLimit = Duration(minutes: 10); // then game cancelled
const Duration roomCleanupAge = Duration(hours: 1);

/// Minimal Firebase Realtime Database client (REST API).
class Db {
  static Uri _u(String path, [String query = '']) {
    final base = firebaseDbUrl.endsWith('/')
        ? firebaseDbUrl.substring(0, firebaseDbUrl.length - 1)
        : firebaseDbUrl;
    return Uri.parse('$base/$path.json$query');
  }

  static Future<dynamic> get(String path, {String query = ''}) async {
    final r = await http.get(_u(path, query));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  static Future<dynamic> put(String path, Object? data) async {
    final r = await http.put(_u(path), body: jsonEncode(data));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  static Future<dynamic> post(String path, Object? data) async {
    final r = await http.post(_u(path), body: jsonEncode(data));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  static Future<void> delete(String path) async {
    await http.delete(_u(path));
  }
}

/// What this phone remembers about its online game (players, not hosts).
class Session {
  static Future<List<String>?> load() async {
    final p = await SharedPreferences.getInstance();
    final code = p.getString('room');
    final id = p.getString('id');
    return (code == null || id == null) ? null : [code, id];
  }

  static Future<void> save(String code, String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('room', code);
    await p.setString('id', id);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('room');
    await p.remove('id');
  }
}

/// Deletes rooms whose host has been silent for over an hour (and their chat),
/// and chat messages whose room no longer exists.
Future<void> cleanOldRooms() async {
  try {
    final rooms = await Db.get('rooms', query: '?shallow=true');
    final roomKeys =
        rooms is Map ? rooms.keys.map((k) => '$k').toSet() : <String>{};
    if (roomKeys.isNotEmpty) {
      final sn = await Db.put('meta/now', {'.sv': 'timestamp'});
      final now =
          sn is num ? sn.toInt() : DateTime.now().millisecondsSinceEpoch;
      var n = 0;
      for (final code in roomKeys) {
        if (n++ >= 20) break;
        final beat = await Db.get('rooms/$code/hostBeat');
        if (beat is! num ||
            now - beat.toInt() > roomCleanupAge.inMilliseconds) {
          await Db.delete('rooms/$code');
          await Db.delete('chat/$code');
        }
      }
    }
    final chats = await Db.get('chat', query: '?shallow=true');
    if (chats is Map) {
      for (final c in chats.keys) {
        if (!roomKeys.contains('$c')) await Db.delete('chat/$c');
      }
    }
  } catch (_) {}
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// Same text as the local game: combo, Trạng Nguyên + tuổi, who was robbed.
String resultMessage(TurnOutcome out) {
  final r = out.roll;
  if (r.names.isEmpty) return '${out.player.name}: không trúng gì';
  final lines = ['${out.player.name}: ${r.names.join(' + ')}'];
  final tr = r.trang;
  if (tr != null) {
    lines.add('Trạng Nguyên${tr.age == null ? '' : ' ${tr.age} tuổi'}');
  } else if (r.winEverything || r.winAllRemaining) {
    lines.add('Lấy hết thẻ của người chơi khác');
  }
  if (out.victims.isNotEmpty) {
    final who = out.victims.map((v) => v.name).join(', ');
    lines.add('${out.player.name} cướp trạng của $who');
  }
  if (out.note != null) lines.add(out.note!);
  return lines.join('\n');
}

/// Everything the other phones need to show the game after a turn.
Map<String, dynamic> snapshotOf(
    XamHuongGame g, List<String> ids, int seq, TurnOutcome? out,
    {String? notice}) {
  Map<String, int> tiles(Map<Tile, int> m) =>
      {for (final t in Tile.values) t.name: m[t] ?? 0};
  final holder = g.trangHolder;
  return {
    'seq': seq,
    'ids': ids,
    'names': [for (final p in g.players) p.name],
    'bots': [for (final p in g.players) p.isBot],
    'notice': notice,
    'current': g.current,
    'over': g.gameOver,
    'stock': tiles(g.bank.stock),
    'players': [
      for (final p in g.players) {'tiles': tiles(p.tiles), 'score': p.score},
    ],
    'discount': g.discountStage,
    'trangIdx': holder == null ? -1 : g.players.indexOf(holder),
    'trangLabel': g.trangInfo?.label ?? '',
    'last': out == null
        ? null
        : {
            'by': g.players.indexOf(out.player),
            'dice': out.roll.dice,
            'message': resultMessage(out),
            'glow': [
              for (final e in out.award.tiles.entries)
                if (e.value > 0) e.key.name,
            ],
            'victims': [for (final v in out.victims) g.players.indexOf(v)],
            'big': out.award.points > 16 || out.stolenPoints > 16,
            'huge': out.award.points + out.stolenPoints >= 32 ||
                out.roll.winEverything ||
                out.roll.winAllRemaining,
          },
  };
}

// ---------------------------------------------------------------- menu

class OnlineMenuScreen extends StatefulWidget {
  const OnlineMenuScreen({super.key});

  @override
  State<OnlineMenuScreen> createState() => _OnlineMenuScreenState();
}

class _OnlineMenuScreenState extends State<OnlineMenuScreen> {
  final _name = TextEditingController(text: 'Người chơi');
  final _code = TextEditingController();
  final _rng = Random();
  bool _busy = false;

  List<String>? _resume; // [code, id] when there is a game to go back to
  Map<String, dynamic>? _resumeSnap; // null = back to the waiting room

  @override
  void initState() {
    super.initState();
    if (onlineConfigured) {
      cleanOldRooms();
      _checkSession();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _playerName =>
      _name.text.trim().isEmpty ? 'Người chơi' : _name.text.trim();

  // Ids start with a letter so Firebase never turns them into a list.
  String _newId() => 'p${_rng.nextInt(1 << 30).toRadixString(36)}';

  Map<String, dynamic> _playerData() => {
        'name': _playerName,
        't': DateTime.now().millisecondsSinceEpoch,
        'beat': DateTime.now().millisecondsSinceEpoch,
      };

  /// Does this phone remember a game it can go back to?
  Future<void> _checkSession() async {
    try {
      final s = await Session.load();
      if (s == null) return;
      final room = await Db.get('rooms/${s[0]}');
      final players = room is Map ? room['players'] : null;
      if (room is! Map || players is! Map || !players.containsKey(s[1])) {
        await Session.clear();
        return;
      }
      if (room['status'] != 'playing') {
        if (mounted) setState(() => _resume = s);
        return;
      }
      final raw = room['state'];
      if (raw is! String) return;
      final snap = jsonDecode(raw) as Map<String, dynamic>;
      final idx = List<String>.from(snap['ids'] as List).indexOf(s[1]);
      final bots = (snap['bots'] as List?) ?? const [];
      if (idx < 0 || (idx < bots.length && bots[idx] == true)) {
        await Session.clear();
        if (mounted) {
          toast(context, 'Bạn đã vắng quá 5 phút nên bot đã chơi thay bạn.');
        }
        return;
      }
      if (snap['over'] == true) {
        await Session.clear();
        return;
      }
      if (mounted) {
        setState(() {
          _resume = s;
          _resumeSnap = snap;
        });
      }
    } catch (_) {}
  }

  Future<void> _doResume() async {
    final s = _resume!;
    final snap = _resumeSnap;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => snap == null
          ? OnlineLobbyScreen(code: s[0], myId: s[1], isHost: false)
          : OnlineGameScreen(
              code: s[0], myId: s[1], isHost: false, initial: snap),
    ));
    if (!mounted) return;
    setState(() {
      _resume = null;
      _resumeSnap = null;
    });
    _checkSession();
  }

  /// Starting or joining another room gives up the old seat: it turns into a bot.
  Future<void> _abandonOld() async {
    final s = await Session.load();
    if (s == null) return;
    try {
      final room = await Db.get('rooms/${s[0]}');
      if (room is Map) {
        if (room['status'] == 'playing') {
          await Db.put('rooms/${s[0]}/players/${s[1]}/left', true);
        } else {
          await Db.delete('rooms/${s[0]}/players/${s[1]}');
        }
      }
    } catch (_) {}
    await Session.clear();
    if (mounted) {
      setState(() {
        _resume = null;
        _resumeSnap = null;
      });
    }
  }

  Future<void> _create() async {
    if (!onlineConfigured) {
      toast(context, 'Chưa cấu hình Firebase cho game.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _abandonOld();
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      String code;
      do {
        code = List.generate(4, (_) => chars[_rng.nextInt(chars.length)])
            .join();
      } while (await Db.get('rooms/$code') != null);
      final id = _newId();
      await Db.put('rooms/$code', {
        'host': id,
        'status': 'lobby',
        'hostBeat': {'.sv': 'timestamp'},
        'players': {id: _playerData()},
      });
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            OnlineLobbyScreen(code: code, myId: id, isHost: true),
      ));
    } catch (_) {
      if (mounted) {
        toast(context, 'Không kết nối được. Kiểm tra mạng và cấu hình Firebase.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    if (!onlineConfigured) {
      toast(context, 'Chưa cấu hình Firebase cho game.');
      return;
    }
    final code = _code.text.trim().toUpperCase();
    if (code.length != 4) {
      toast(context, 'Nhập mã phòng gồm 4 ký tự.');
      return;
    }
    if (_resume != null && _resume![0] == code) {
      _doResume(); // typing the code of your own game goes back to it
      return;
    }
    setState(() => _busy = true);
    try {
      final room = await Db.get('rooms/$code');
      if (room is! Map) {
        if (mounted) toast(context, 'Không tìm thấy phòng $code.');
        return;
      }
      if (room['status'] != 'lobby') {
        if (mounted) toast(context, 'Phòng này đã bắt đầu chơi.');
        return;
      }
      final players = room['players'];
      if (players is Map && players.length >= maxOnlinePlayers) {
        if (mounted) toast(context, 'Phòng đã đủ $maxOnlinePlayers người.');
        return;
      }
      await _abandonOld();
      final id = _newId();
      await Db.put('rooms/$code/players/$id', _playerData());
      await Session.save(code, id);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            OnlineLobbyScreen(code: code, myId: id, isHost: false),
      ));
    } catch (_) {
      if (mounted) {
        toast(context, 'Không kết nối được. Kiểm tra mạng và cấu hình Firebase.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chơi online')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_resume != null) ...[
                    FilledButton.icon(
                      onPressed: _doResume,
                      icon: const Icon(Icons.replay),
                      label: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text('Quay lại phòng ${_resume![0]}',
                            style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                    const SizedBox(height: 28),
                  ],
                  TextField(
                    controller: _name,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      labelText: 'Tên của bạn',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _create,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('Tạo phòng', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text('hoặc nhập mã phòng để vào'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _code,
                    maxLength: 4,
                    textCapitalization: TextCapitalization.characters,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 6),
                    decoration: const InputDecoration(
                      labelText: 'Mã phòng',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : _join,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('Vào phòng', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- lobby

class OnlineLobbyScreen extends StatefulWidget {
  final String code;
  final String myId;
  final bool isHost;
  const OnlineLobbyScreen({
    super.key,
    required this.code,
    required this.myId,
    required this.isHost,
  });

  @override
  State<OnlineLobbyScreen> createState() => _OnlineLobbyScreenState();
}

class _OnlineLobbyScreenState extends State<OnlineLobbyScreen> {
  Timer? _timer;
  bool _polling = false;
  bool _leaving = false; // started the game, or closed the room
  List<MapEntry<String, String>> _players = [];
  String _hostId = '';

  DateTime _lastBeatWrite = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, dynamic> _lastBeat = {};
  final Map<String, DateTime> _seenAt = {};

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _sendBeat() async {
    final now = DateTime.now();
    if (now.difference(_lastBeatWrite) < beatEvery) return;
    _lastBeatWrite = now;
    if (widget.isHost) {
      await Db.put('rooms/${widget.code}/hostBeat', {'.sv': 'timestamp'});
    } else {
      await Db.put('rooms/${widget.code}/players/${widget.myId}/beat',
          now.millisecondsSinceEpoch);
    }
  }

  Future<void> _poll() async {
    if (_polling || _leaving) return;
    _polling = true;
    var joining = false;
    try {
      final room = await Db.get('rooms/${widget.code}');
      if (!mounted || _leaving) return;
      if (room is! Map) {
        if (!widget.isHost) {
          _leaving = true;
          await Session.clear();
          if (!mounted) return;
          toast(context, 'Phòng đã đóng.');
          Navigator.of(context).pop();
        }
        return;
      }
      final now = DateTime.now();
      final list = <MapEntry<String, Map>>[];
      final pm = room['players'];
      if (pm is Map) {
        pm.forEach((k, v) {
          if (v is Map) list.add(MapEntry('$k', v));
        });
      }
      list.sort((a, b) =>
          ((a.value['t'] ?? 0) as num).compareTo((b.value['t'] ?? 0) as num));
      final hostId = '${room['host']}';
      // Hide players whose phone went quiet (closed the app in the lobby).
      final shown = <MapEntry<String, String>>[];
      for (final e in list) {
        final beat = e.value['beat'];
        if (beat != _lastBeat[e.key]) {
          _lastBeat[e.key] = beat;
          _seenAt[e.key] = now;
        }
        final quiet = now.difference(_seenAt[e.key] ?? now) > lobbyQuietLimit;
        if (e.key == hostId || e.key == widget.myId || !quiet) {
          shown.add(MapEntry(e.key, '${e.value['name']}'));
        }
      }
      setState(() {
        _hostId = hostId;
        _players = shown;
      });
      await _sendBeat();
      if (room['status'] == 'playing' && !widget.isHost) {
        _leaving = true;
        joining = true;
        final raw = await Db.get('rooms/${widget.code}/state');
        final snap = jsonDecode(raw as String) as Map<String, dynamic>;
        if (!mounted) return;
        if (!List<String>.from(snap['ids'] as List).contains(widget.myId)) {
          await Session.clear();
          if (!mounted) return;
          toast(context, 'Ván đã bắt đầu mà không có bạn.');
          Navigator.of(context).pop();
          return;
        }
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => OnlineGameScreen(
            code: widget.code,
            myId: widget.myId,
            isHost: false,
            initial: snap,
          ),
        ));
      }
    } catch (_) {
      // Network hiccup: try again on the next tick.
      if (joining) _leaving = false;
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    if (_players.length < 2 || _leaving) return;
    setState(() => _leaving = true);
    try {
      final ids = [for (final e in _players) e.key];
      final names = [for (final e in _players) e.value];
      final game = XamHuongGame([for (final n in names) Player(n)]);
      final snap = snapshotOf(game, ids, 0, null);
      await Db.put('rooms/${widget.code}/state', jsonEncode(snap));
      await Db.put('rooms/${widget.code}/status', 'playing');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => OnlineGameScreen(
          code: widget.code,
          myId: widget.myId,
          isHost: true,
          initial: snap,
          game: game,
        ),
      ));
    } catch (_) {
      if (mounted) {
        setState(() => _leaving = false);
        toast(context, 'Không bắt đầu được, thử lại nhé.');
      }
    }
  }

  Future<void> _leave() async {
    _leaving = true;
    try {
      if (widget.isHost) {
        await Db.delete('rooms/${widget.code}');
      } else {
        await Db.delete('rooms/${widget.code}/players/${widget.myId}');
        await Session.clear();
      }
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canStart = widget.isHost && _players.length >= 2 && !_leaving;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Phòng chờ')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Mã phòng'),
                    SelectableText(
                      widget.code,
                      style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8),
                    ),
                    const SizedBox(height: 4),
                    Text('Người chơi (${_players.length}/$maxOnlinePlayers)'),
                    const SizedBox(height: 8),
                    for (final p in _players)
                      Card(
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                              p.key == _hostId ? Icons.star : Icons.person),
                          title: Text(
                              '${p.value}${p.key == widget.myId ? ' (bạn)' : ''}'),
                          trailing: p.key == _hostId
                              ? const Text('Chủ phòng')
                              : null,
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (widget.isHost)
                      FilledButton(
                        onPressed: canStart ? _start : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 8),
                          child: Text(
                              _players.length < 2
                                  ? 'Cần ít nhất 2 người'
                                  : 'Bắt đầu chơi',
                              style: const TextStyle(fontSize: 18)),
                        ),
                      )
                    else
                      const Text('Đang chờ chủ phòng bắt đầu...'),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _leave,
                      child: Text(widget.isHost ? 'Hủy phòng' : 'Rời phòng'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- game

class OnlineGameScreen extends StatefulWidget {
  final String code;
  final String myId;
  final bool isHost;
  final Map<String, dynamic> initial;
  final XamHuongGame? game; // host only
  const OnlineGameScreen({
    super.key,
    required this.code,
    required this.myId,
    required this.isHost,
    required this.initial,
    this.game,
  });

  @override
  State<OnlineGameScreen> createState() => _OnlineGameScreenState();
}

class _OnlineGameScreenState extends State<OnlineGameScreen> {
  final _rng = Random();
  final _clinks = List.generate(3, (_) => AudioPlayer());
  final _sfx = AudioPlayer();
  int _clinkIdx = 0;

  Timer? _timer;
  bool _ticking = false;
  DateTime _now = DateTime.now();
  DateTime _lastBeatWrite = DateTime.fromMillisecondsSinceEpoch(0);

  late List<String> ids;
  late List<String> names;
  late Map<String, dynamic> snap; // the snapshot currently on screen

  int _seq = 0; // host: newest snapshot written
  int _receivedSeq = 0; // newest snapshot seen
  Map<String, dynamic>? _pending;
  Map<String, dynamic>? _unsent; // host: snapshot not yet in the database
  bool _draining = false;

  // Who has been quiet (observed on this phone, so no clock differences).
  dynamic _lastHostBeat;
  DateTime _hostSeenAt = DateTime.now();
  final Map<String, dynamic> _lastBeat = {};
  final Map<String, DateTime> _seenAt = {};

  Set<Tile> glowing = {};
  Set<int> glowingPlayers = {};
  List<int> faces = [1, 2, 3, 4, 5, 6];
  List<double> angles = List.filled(6, 0.0);
  bool busy = false;
  int? _highlight; // the roller stays highlighted during the pause
  bool waitingRoll = false;
  bool _cancelled = false; // the host is gone
  bool _kicked = false; // we were away too long and a bot took over
  bool _cleaned = false;
  String message = '';

  // chat
  final _danmaku = GlobalKey<DanmakuLayerState>();
  bool _danmakuOn = true;
  Offset? _chatPos;
  String? _lastChatKey;
  int _tickCount = 0;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  XamHuongGame? get _game => widget.game;

  @override
  void initState() {
    super.initState();
    snap = widget.initial;
    ids = List<String>.from(snap['ids'] as List);
    names = List<String>.from(snap['names'] as List);
    _seq = snap['seq'] as int;
    _receivedSeq = _seq;
    message = _turnText(snap);
    if (!widget.isHost) Session.save(widget.code, widget.myId);
    _loadChatPrefs();
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final p in _clinks) {
      p.dispose();
    }
    _sfx.dispose();
    super.dispose();
  }

  int get _myIdx => ids.indexOf(widget.myId);
  int get _current => snap['current'] as int;
  bool get _over => snap['over'] == true;
  List get _players => snap['players'] as List;
  bool get _canLeave => _over || _cancelled || _kicked;

  bool get _meBot {
    final b = (snap['bots'] as List?) ?? const [];
    final i = _myIdx;
    return i >= 0 && i < b.length && b[i] == true;
  }

  String _turnText(Map<String, dynamic> s) {
    final cur = s['current'] as int;
    return cur == _myIdx ? 'Tới lượt bạn, bấm Gieo!' : 'Tới lượt ${names[cur]}';
  }

  Map<Tile, int> _tiles(dynamic m) => {
        for (final t in Tile.values) t: ((m as Map)[t.name] ?? 0) as int,
      };

  Future<void> _wait(int ms) => Future.delayed(Duration(milliseconds: ms));

  void _clink() {
    final p = _clinks[_clinkIdx++ % _clinks.length];
    p.play(AssetSource('sounds/clink.wav'));
  }

  // ---- talking to the database

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final room = await Db.get('rooms/${widget.code}');
      if (!mounted) return;
      _now = DateTime.now();
      if (room is! Map) {
        if (!_over && !_draining && _pending == null) _cancel();
        return;
      }
      if (widget.isHost) {
        await _hostTick(room);
      } else {
        _clientTick(room);
      }
      final raw = room['state'];
      if (raw is String) _receive(jsonDecode(raw) as Map<String, dynamic>);
      await _beat();
      if (_tickCount++ % 2 == 0) await _pollChat();
    } catch (_) {
      // Network hiccup: try again on the next tick.
    } finally {
      _ticking = false;
    }
  }

  Future<void> _beat() async {
    if (_now.difference(_lastBeatWrite) < beatEvery) return;
    _lastBeatWrite = _now;
    if (widget.isHost) {
      await Db.put('rooms/${widget.code}/hostBeat', {'.sv': 'timestamp'});
    } else {
      await Db.put('rooms/${widget.code}/players/${widget.myId}/beat',
          _now.millisecondsSinceEpoch);
    }
  }

  /// Player side: has the host been quiet for too long?
  void _clientTick(Map room) {
    final hb = room['hostBeat'];
    if (hb != _lastHostBeat) {
      _lastHostBeat = hb;
      _hostSeenAt = _now;
    } else if (!_over && _now.difference(_hostSeenAt) > hostAwayLimit) {
      _cancel();
    }
  }

  void _cancel() {
    if (_cancelled || _kicked) return;
    _timer?.cancel();
    Session.clear();
    setState(() {
      _cancelled = true;
      busy = false;
      message = 'Chủ phòng đã thoát, ván đấu bị hủy';
    });
  }

  void _kick() {
    if (_kicked) return;
    _timer?.cancel();
    Session.clear();
    setState(() {
      _kicked = true;
      message = 'Bạn đã vắng quá 5 phút nên bot đã chơi thay bạn.';
    });
  }

  Future<void> _flush() async {
    final s = _unsent;
    if (s == null) return;
    await Db.put('rooms/${widget.code}/state', jsonEncode(s));
    if (identical(_unsent, s)) _unsent = null;
  }

  /// Host: bots play, absent players become bots, roll requests are served.
  Future<void> _hostTick(Map room) async {
    final g = _game!;
    await _flush();
    if (g.gameOver || _draining || _unsent != null) return;

    // Players who left or have been quiet for 5 minutes become bots.
    final pm = room['players'];
    if (pm is Map) {
      for (var i = 0; i < ids.length; i++) {
        final p = g.players[i];
        if (p.isBot || ids[i] == widget.myId) continue;
        final d = pm[ids[i]];
        if (d is! Map) continue;
        final beat = d['beat'];
        if (beat != _lastBeat[ids[i]]) {
          _lastBeat[ids[i]] = beat;
          _seenAt[ids[i]] = _now;
        }
        final quiet = _now.difference(_seenAt[ids[i]] ?? _now) > playerAwayLimit;
        if (d['left'] == true || quiet) {
          await _convert(i);
          return;
        }
      }
    }

    // A bot's turn: roll for it.
    if (g.currentPlayer.isBot) {
      await _hostPlay();
      return;
    }

    // A real player asked to roll.
    final cmd = room['cmd'];
    if (cmd is! Map || cmd['seq'] != _seq + 1) return;
    if (ids.indexOf('${cmd['by']}') != g.current) return;
    await _hostPlay();
  }

  Future<void> _convert(int i) async {
    final g = _game!;
    final old = g.players[i].name;
    g.convertToBot(i);
    _seq++;
    final s = snapshotOf(g, ids, _seq, null,
        notice: '$old đã thoát. ${g.players[i].name} chơi thay.');
    _unsent = s;
    _receive(s);
    await _flush();
  }

  Future<void> _hostPlay() async {
    final g = _game!;
    final out = g.playTurn();
    _seq++;
    final s = snapshotOf(g, ids, _seq, out);
    _unsent = s;
    _receive(s);
    await _flush();
  }

  Future<void> _roll() async {
    setState(() => waitingRoll = true);
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && waitingRoll && !busy) setState(() => waitingRoll = false);
    });
    try {
      if (widget.isHost) {
        await _hostPlay();
      } else {
        await Db.put('rooms/${widget.code}/cmd',
            {'by': widget.myId, 'seq': _receivedSeq + 1});
      }
    } catch (_) {
      if (mounted) setState(() => waitingRoll = false);
    }
  }

  // ---- showing a new snapshot

  void _receive(Map<String, dynamic> s) {
    final seq = s['seq'] as int;
    if (seq <= _receivedSeq) return;
    _receivedSeq = seq;
    _pending = s;
    waitingRoll = false;
    if (!_draining) _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    while (_pending != null && mounted) {
      final s = _pending!;
      _pending = null;
      await _apply(s);
    }
    _draining = false;
  }

  Future<void> _apply(Map<String, dynamic> s) async {
    names = List<String>.from(s['names'] as List);
    final last = s['last'];
    if (last is! Map) {
      setState(() {
        snap = s;
        message = (s['notice'] as String?) ?? _turnText(s);
      });
      if (_meBot) _kick();
      return;
    }
    final by = last['by'] as int;
    setState(() {
      busy = true;
      _highlight = by;
      message = '${names[by]} đang gieo...';
    });
    for (var i = 0; i < 12; i++) {
      _clink();
      setState(() {
        faces = List.generate(6, (_) => _rng.nextInt(6) + 1);
        angles = List.generate(6, (_) => (_rng.nextDouble() - 0.5) * 1.2);
      });
      await _wait(122);
      if (!mounted) return;
    }
    setState(() {
      faces = List<int>.from(last['dice'] as List);
      angles = List.filled(6, 0.0);
      message = '${last['message']}';
    });
    await _wait(last['big'] == true ? 3000 : 2000);
    if (!mounted) return;
    setState(() {
      glowing = {
        for (final n in last['glow'] as List) Tile.values.byName('$n'),
      };
      glowingPlayers = {for (final v in last['victims'] as List) v as int};
    });
    await _wait(1000);
    if (!mounted) return;
    setState(() {
      glowing = {};
      glowingPlayers = {};
      snap = s;
    });
    await _wait(500);
    if (!mounted) return;
    if (last['huge'] == true) {
      await _wait(3000); // 32+ points: stay a bit longer
      if (!mounted) return;
    }
    setState(() {
      busy = false;
      _highlight = null;
    });
    if (s['over'] == true) {
      _endGame();
    } else if (_meBot) {
      _kick();
    }
  }

  void _endGame() {
    _timer?.cancel();
    Session.clear();
    final scores = [for (final p in _players) (p as Map)['score'] as int];
    if (scores[_myIdx] == scores.reduce(max)) {
      _sfx.play(AssetSource('sounds/applause.wav'));
    }
    _showResult();
  }

  void _showResult() {
    final order = List<int>.generate(_players.length, (i) => i)
      ..sort((a, b) => ((_players[b] as Map)['score'] as int)
          .compareTo((_players[a] as Map)['score'] as int));
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Điểm số cuối cùng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final i in order)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                    '${names[i]}: ${(_players[i] as Map)['score']} điểm',
                    style: const TextStyle(fontSize: 16)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  // ---- chat

  Future<void> _loadChatPrefs() async {
    final p = await SharedPreferences.getInstance();
    final x = p.getDouble('chatx');
    final y = p.getDouble('chaty');
    if (!mounted) return;
    setState(() {
      _danmakuOn = p.getBool('danmaku') ?? true;
      if (x != null && y != null) _chatPos = Offset(x, y);
    });
  }

  Future<void> _saveChatPos(Offset o) async {
    setState(() => _chatPos = o);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('chatx', o.dx);
    await p.setDouble('chaty', o.dy);
  }

  Future<void> _setDanmaku(bool v) async {
    setState(() => _danmakuOn = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('danmaku', v);
  }

  /// Returns an error text, or null when the message was sent.
  String? _sendChat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 'Nhập nội dung trước nhé.';
    final now = DateTime.now();
    if (now.difference(_lastSent) < const Duration(milliseconds: 1500)) {
      return 'Gửi chậm lại một chút nhé.';
    }
    _lastSent = now;
    _danmaku.currentState?.add('Bạn: $text');
    final name = _myIdx >= 0 ? names[_myIdx] : 'Người chơi';
    Db.post('chat/${widget.code}', {'i': widget.myId, 'n': name, 't': text})
        .catchError((_) {});
    return null;
  }

  void _openChat() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatSheet(
        onSend: _sendChat,
        danmakuOn: _danmakuOn,
        onToggle: _setDanmaku,
      ),
    );
  }

  /// Shows messages that arrived since the last look (no history on entering).
  Future<void> _pollChat() async {
    final data = await Db.get('chat/${widget.code}',
        query: '?orderBy=%22%24key%22&limitToLast=10');
    if (data is! Map || data.isEmpty) {
      _lastChatKey ??= '';
      return;
    }
    final keys = data.keys.map((k) => '$k').toList()..sort();
    if (_lastChatKey == null) {
      _lastChatKey = keys.last;
      return;
    }
    for (final k in keys) {
      if (k.compareTo(_lastChatKey!) <= 0) continue;
      final m = data[k];
      if (m is Map && m['i'] != widget.myId) {
        _danmaku.currentState?.add('${m['n']}: ${m['t']}');
      }
      _lastChatKey = k;
    }
  }

  // ---- leaving

  Future<void> _cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    _timer?.cancel();
    await Session.clear();
    if (widget.isHost) {
      try {
        await Db.delete('rooms/${widget.code}');
        await Db.delete('chat/${widget.code}');
      } catch (_) {}
    }
  }

  Future<void> _exit() async {
    await _cleanup();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.isHost ? 'Hủy ván?' : 'Rời ván?'),
        content: Text(widget.isHost
            ? 'Ván sẽ bị hủy cho tất cả mọi người.'
            : 'Bạn sẽ không vào lại được, bot sẽ chơi thay bạn.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Ở lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đồng ý'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!widget.isHost) {
      try {
        await Db.put('rooms/${widget.code}/players/${widget.myId}/left', true);
      } catch (_) {}
    }
    await _exit();
  }

  @override
  Widget build(BuildContext context) {
    final trangIdx = snap['trangIdx'] as int;
    final trangLabel = '${snap['trangLabel']}';
    final myTurn = !busy &&
        !waitingRoll &&
        !_draining &&
        !_canLeave &&
        _current == _myIdx;
    final status = _canLeave
        ? ''
        : myTurn
            ? 'Tới lượt bạn'
            : (busy || _draining ? '' : 'Chờ ${names[_current]} gieo...');
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _cleanup();
      },
      child: Scaffold(
        body: Stack(
          children: [
          SafeArea(
          top: false,
          child: CustomScrollView(
            slivers: [
              // Scrolls away with the page; shows again at the top of the page.
              SliverAppBar(
                automaticallyImplyLeading: _canLeave,
                title: Text('Phòng ${widget.code}'),
                actions: [
                  if (!_canLeave)
                    PopupMenuButton<String>(
                      onSelected: (_) => _confirmLeave(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'leave',
                          child: Text(widget.isHost ? 'Hủy ván' : 'Rời ván'),
                        ),
                      ],
                    ),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                BankGrid(
                  stock: _tiles(snap['stock']),
                  glowing: glowing,
                  discount: snap['discount'] as int,
                ),
                const SizedBox(height: 12),
                DiceBowl(faces: faces, angles: angles),
                const SizedBox(height: 12),
                SizedBox(
                  height: 84,
                  child: Center(
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                SizedBox(
                  height: 24,
                  child: Text(status, style: const TextStyle(fontSize: 13)),
                ),
                FilledButton(
                  onPressed: _canLeave ? _exit : (myTurn ? _roll : null),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 10),
                    child: Text(_canLeave ? 'Thoát' : 'Gieo',
                        style: const TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _over ? _showResult : null,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const Icon(Icons.emoji_events, size: 18),
                  label: const Text('Xem kết quả'),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < _players.length; i++)
                  PlayerTile(
                    name: names[i] + (i == _myIdx ? ' (bạn)' : ''),
                    tiles: tilesText(_tiles((_players[i] as Map)['tiles']),
                        i == trangIdx ? trangLabel : ''),
                    score: (_players[i] as Map)['score'] as int,
                    current: i == (_highlight ?? _current) && !_over,
                    glow: glowingPlayers.contains(i),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
          Positioned.fill(
            child: IgnorePointer(
              child: DanmakuLayer(
                key: _danmaku,
                enabled: _danmakuOn,
                topOffset: MediaQuery.of(context).padding.top + 64,
              ),
            ),
          ),
          if (!_canLeave)
            Positioned.fill(
              child: ChatButton(
                initial: _chatPos,
                onTap: _openChat,
                onMoved: _saveChatPos,
              ),
            ),
        ],
      ),
    ),
  );
  }
}
