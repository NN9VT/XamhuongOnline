// Xăm hường - simple online play through a Firebase Realtime Database.
//
// The host's phone runs the game. Other players send a "roll" request, the host
// rolls and writes a snapshot, and every phone plays the same animation from it.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'online_config.dart';
import 'widgets.dart';
import 'xam_huong_engine.dart';
import 'xam_huong_game.dart';

const int maxOnlinePlayers = 4;

/// Minimal Firebase Realtime Database client (REST API).
class Db {
  static Uri _u(String path) {
    final base = firebaseDbUrl.endsWith('/')
        ? firebaseDbUrl.substring(0, firebaseDbUrl.length - 1)
        : firebaseDbUrl;
    return Uri.parse('$base/$path.json');
  }

  static Future<dynamic> get(String path) async {
    final r = await http.get(_u(path));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  static Future<void> put(String path, Object? data) async {
    final r = await http.put(_u(path), body: jsonEncode(data));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  }

  static Future<void> delete(String path) async {
    await http.delete(_u(path));
  }
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
Map<String, dynamic> snapshotOf(XamHuongGame g, List<String> ids,
    List<String> names, int seq, TurnOutcome? out) {
  Map<String, int> tiles(Map<Tile, int> m) =>
      {for (final t in Tile.values) t.name: m[t] ?? 0};
  final holder = g.trangHolder;
  return {
    'seq': seq,
    'ids': ids,
    'names': names,
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

  Map<String, dynamic> _playerData() =>
      {'name': _playerName, 't': DateTime.now().millisecondsSinceEpoch};

  Future<void> _create() async {
    if (!onlineConfigured) {
      toast(context, 'Chưa cấu hình Firebase cho game.');
      return;
    }
    setState(() => _busy = true);
    try {
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
      final id = _newId();
      await Db.put('rooms/$code/players/$id', _playerData());
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
          toast(context, 'Phòng đã đóng.');
          Navigator.of(context).pop();
        }
        return;
      }
      final list = <MapEntry<String, Map>>[];
      final pm = room['players'];
      if (pm is Map) {
        pm.forEach((k, v) {
          if (v is Map) list.add(MapEntry('$k', v));
        });
      }
      list.sort((a, b) =>
          ((a.value['t'] ?? 0) as num).compareTo((b.value['t'] ?? 0) as num));
      setState(() {
        _hostId = '${room['host']}';
        _players = [for (final e in list) MapEntry(e.key, '${e.value['name']}')];
      });
      if (room['status'] == 'playing' && !widget.isHost) {
        _leaving = true;
        joining = true;
        final raw = await Db.get('rooms/${widget.code}/state');
        final snap = jsonDecode(raw as String) as Map<String, dynamic>;
        if (!mounted) return;
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
      final snap = snapshotOf(game, ids, names, 0, null);
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
      }
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canStart = widget.isHost && _players.length >= 2 && !_leaving;
    return Scaffold(
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
                        trailing:
                            p.key == _hostId ? const Text('Chủ phòng') : null,
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

  late List<String> ids;
  late List<String> names;
  late Map<String, dynamic> snap; // the snapshot currently on screen

  int _seq = 0; // host: newest snapshot written
  int _receivedSeq = 0; // newest snapshot seen
  Map<String, dynamic>? _pending;
  Map<String, dynamic>? _unsent; // host: snapshot not yet in the database
  bool _draining = false;

  Set<Tile> glowing = {};
  Set<int> glowingPlayers = {};
  List<int> faces = [1, 2, 3, 4, 5, 6];
  List<double> angles = List.filled(6, 0.0);
  bool busy = false;
  bool waitingRoll = false;
  String message = '';

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
      if (widget.isHost) {
        await _flush();
        await _hostCheck();
      }
      final raw = await Db.get('rooms/${widget.code}/state');
      if (raw is String && mounted) {
        _receive(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // Network hiccup: try again on the next tick.
    } finally {
      _ticking = false;
    }
  }

  Future<void> _flush() async {
    final s = _unsent;
    if (s == null) return;
    await Db.put('rooms/${widget.code}/state', jsonEncode(s));
    if (identical(_unsent, s)) _unsent = null;
  }

  /// Host: is there a valid roll request from the player whose turn it is?
  Future<void> _hostCheck() async {
    final g = _game;
    if (g == null || _draining || g.gameOver || _unsent != null) return;
    final cmd = await Db.get('rooms/${widget.code}/cmd');
    if (cmd is! Map || cmd['seq'] != _seq + 1) return;
    if (ids.indexOf('${cmd['by']}') != g.current) return;
    await _hostPlay();
  }

  Future<void> _hostPlay() async {
    final g = _game!;
    final out = g.playTurn();
    _seq++;
    final s = snapshotOf(g, ids, names, _seq, out);
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
    final last = s['last'];
    if (last is! Map) {
      setState(() {
        snap = s;
        message = _turnText(s);
      });
      return;
    }
    final by = last['by'] as int;
    setState(() {
      busy = true;
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
    setState(() => busy = false);
    if (s['over'] == true) _endGame();
  }

  void _endGame() {
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

  Future<void> _exit() async {
    if (widget.isHost) {
      try {
        await Db.delete('rooms/${widget.code}');
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final trangIdx = snap['trangIdx'] as int;
    final trangLabel = '${snap['trangLabel']}';
    final myTurn = !busy &&
        !waitingRoll &&
        !_draining &&
        !_over &&
        _current == _myIdx;
    final status = _over
        ? ''
        : myTurn
            ? 'Tới lượt bạn'
            : (busy || _draining ? '' : 'Chờ ${names[_current]} gieo...');
    return Scaffold(
      appBar: AppBar(title: Text('Phòng ${widget.code}')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
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
                onPressed: _over ? _exit : (myTurn ? _roll : null),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
                  child: Text(_over ? 'Thoát' : 'Gieo',
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
                  current: i == _current && !_over,
                  glow: glowingPlayers.contains(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
