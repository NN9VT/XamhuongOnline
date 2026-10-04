import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'online.dart';
import 'xam_huong_engine.dart';
import 'xam_huong_game.dart';

void main() => runApp(const XamHuongApp());

class XamHuongApp extends StatelessWidget {
  const XamHuongApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Xăm Hường',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFB71C1C),
            brightness: Brightness.dark,
          ),
        ),
        home: const SetupScreen(),
      );
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  double bots = 3; // 1 to 7 bots = 2 to 8 players
  final _names =
      List.generate(7, (i) => TextEditingController(text: 'Bot ${i + 1}'));

  @override
  void dispose() {
    for (final c in _names) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = bots.round();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Xăm Hường',
                    style:
                        TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Trò chơi dân gian gieo 6 xí ngầu'),
                const SizedBox(height: 24),
                Text('Số bot: $n (tổng ${n + 1} người chơi)'),
                Slider(
                  value: bots,
                  min: 1,
                  max: 7,
                  divisions: 6,
                  label: '$n',
                  onChanged: (v) => setState(() => bots = v),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < n; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _names[i],
                      maxLength: 12,
                      decoration: InputDecoration(
                        labelText: 'Tên bot ${i + 1}',
                        isDense: true,
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    final names = [
                      for (var i = 0; i < n; i++)
                        _names[i].text.trim().isEmpty
                            ? 'Bot ${i + 1}'
                            : _names[i].text.trim(),
                    ];
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GameScreen(botNames: names),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Text('Bắt đầu chơi', style: TextStyle(fontSize: 18)),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OnlineMenuScreen()),
                  ),
                  icon: const Icon(Icons.public),
                  label: const Text('Chơi online (2-4 người)'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final List<String> botNames;
  const GameScreen({super.key, required this.botNames});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final _rng = Random();
  final _clinks = List.generate(3, (_) => AudioPlayer());
  final _sfx = AudioPlayer();
  int _clinkIdx = 0;

  late XamHuongGame game;

  // What the screen shows. It lags behind `game` during a turn so the tiles
  // can light up on the table before they move to the player.
  late Map<Tile, int> shownStock;
  late List<Map<Tile, int>> shownTiles;
  late List<int> shownScores;
  int shownCurrent = 0;
  int shownDiscount = 0;
  int shownTrangIdx = -1;
  String shownTrangLabel = '';
  Set<Tile> glowing = {};

  List<int> faces = [1, 2, 3, 4, 5, 6];
  List<double> angles = List.filled(6, 0.0);
  bool rolling = false; // true during the whole turn (roll, pause, glow)
  bool paused = false;
  String message = '';
  Set<int> glowingPlayers = {};

  @override
  void initState() {
    super.initState();
    _newGame();
  }

  @override
  void dispose() {
    for (final p in _clinks) {
      p.dispose();
    }
    _sfx.dispose();
    super.dispose();
  }

  void _newGame() {
    game = XamHuongGame([
      Player('Bạn'),
      for (final name in widget.botNames) Player(name, isBot: true),
    ]);
    _syncShown();
    shownCurrent = game.current;
    glowing = {};
    faces = [1, 2, 3, 4, 5, 6];
    angles = List.filled(6, 0.0);
    rolling = false;
    paused = false;
    glowingPlayers = {};
    message = 'Tới lượt bạn, bấm Gieo!';
  }

  void _syncShown() {
    shownStock = Map.of(game.bank.stock);
    shownTiles = [for (final p in game.players) Map.of(p.tiles)];
    shownScores = [for (final p in game.players) p.score];
    shownDiscount = game.discountStage;
    final holder = game.trangHolder;
    final info = game.trangInfo;
    shownTrangIdx = holder == null ? -1 : game.players.indexOf(holder);
    shownTrangLabel = (holder == null || info == null) ? '' : info.label;
  }

  Future<void> _wait(int ms) => Future.delayed(Duration(milliseconds: ms));

  void _clink() {
    final p = _clinks[_clinkIdx++ % _clinks.length];
    p.play(AssetSource('sounds/clink.wav'));
  }

  /// Line 1: combo, line 2: Trạng Nguyên + tuổi, line 3: who was robbed.
  String _resultMessage(TurnOutcome out) {
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

  Future<void> _takeTurn() async {
    if (rolling || game.gameOver) return;
    final player = game.currentPlayer;
    setState(() {
      rolling = true;
      shownCurrent = game.current;
      message = '${player.name} đang gieo...';
    });

    // Rolling animation, about 1.5 seconds.
    for (var i = 0; i < 12; i++) {
      _clink();
      setState(() {
        faces = List.generate(6, (_) => _rng.nextInt(6) + 1);
        angles = List.generate(6, (_) => (_rng.nextDouble() - 0.5) * 1.2);
      });
      await _wait(122);
      if (!mounted) return;
    }

    final out = game.playTurn();
    // Pause for the Trạng results (Tứ Hường, Ngũ Hường, Ngũ Tử, Lục Phú...).
    final special = out.roll.trang != null ||
        out.roll.winEverything ||
        out.roll.winAllRemaining;
    final big = out.award.points > 16 || out.stolenPoints > 16;
    // 32 points or more (Trạng Nguyên and up, steals, Lục Phú...): stay longer.
    final huge = out.award.points + out.stolenPoints >= 32 ||
        out.roll.winEverything ||
        out.roll.winAllRemaining;
    setState(() {
      faces = out.roll.dice;
      angles = List.filled(6, 0.0);
      message = _resultMessage(out);
    });

    // Let everyone read the result (longer for big results).
    await _wait(big ? 3000 : 2000);
    if (!mounted) return;

    // Light up the tiles taken from the table, then give them to the player.
    setState(() {
      glowing = {
        for (final e in out.award.tiles.entries)
          if (e.value > 0) e.key,
      };
      glowingPlayers = {
        for (final v in out.victims) game.players.indexOf(v),
      };
    });
    await _wait(1000);
    if (!mounted) return;
    setState(() {
      glowing = {};
      glowingPlayers = {};
      _syncShown();
    });
    await _wait(500);
    if (!mounted) return;
    if (huge) {
      await _wait(3000);
      if (!mounted) return;
    }

    setState(() {
      rolling = false;
      shownCurrent = game.current;
      if (special) paused = true; // wait for Tiếp tục
    });

    if (game.gameOver) {
      _endGame();
      return;
    }
    if (game.currentPlayer.isBot && !paused) {
      _takeTurn();
    }
  }

  void _togglePause() {
    setState(() => paused = !paused);
    if (!paused && !rolling && !game.gameOver && game.currentPlayer.isBot) {
      _takeTurn();
    }
  }

  void _endGame() {
    final me = game.players.first;
    if (game.winners.contains(me)) {
      _sfx.play(AssetSource('sounds/applause.wav'));
    }
    _showResult();
  }

  void _showResult() {
    final ranked = [...game.players]..sort((a, b) => b.score.compareTo(a.score));
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Điểm số cuối cùng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in ranked)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${p.name}: ${p.score} điểm',
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

  String _tilesText(Map<Tile, int> m, String trangLabel) {
    final s = m.entries.where((e) => e.value > 0).map((e) {
      final extra = (e.key == Tile.trangAnh && trangLabel.isNotEmpty)
          ? ' ($trangLabel)'
          : '';
      return '${e.value}x ${_bankNames[e.key]}$extra';
    }).join(', ');
    return s.isEmpty ? 'Chưa có thẻ' : s;
  }

  // Names shown on the table only (players' cards keep the old names).
  static const Map<Tile, String> _bankNames = {
    Tile.trangAnh: 'Trạng Nguyên',
    Tile.trangEm: 'Bảng Nhãn',
    Tile.tamHuong: 'Hội Nguyên',
    Tile.tuTu: 'Tiến Sỹ',
    Tile.nhiHuong: 'Cử Nhân',
    Tile.nhatHuong: 'Tú Tài',
  };

  Widget _bank() => GridView.builder(
        shrinkWrap: true,
        clipBehavior: Clip.none,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: Tile.values.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 36,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemBuilder: (_, i) {
          final t = Tile.values[i];
          final glow = glowing.contains(t);
          // Giảm giá: Trạng Nguyên gets a slightly lighter background.
          final tint = (t == Tile.trangAnh && shownDiscount > 0)
              ? const Color(0x24FFFFFF)
              : Colors.transparent;
          final bg = Theme.of(context).scaffoldBackgroundColor;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Color.alphaBlend(tint, bg), // opaque: glow stays on the border
              border: Border.all(
                color: glow ? Colors.white : Colors.white24,
                width: glow ? 3 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: glow
                  ? const [
                      BoxShadow(
                          color: Colors.white70, blurRadius: 12, spreadRadius: 2)
                    ]
                  : const [],
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${_bankNames[t]} (${t.points}đ) ×${shownStock[t]}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
        },
      );

  Widget _playerCard(int i) {
    final glow = glowingPlayers.contains(i);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: glow
              ? const [
                  BoxShadow(
                      color: Colors.white70, blurRadius: 12, spreadRadius: 2)
                ]
              : const [],
        ),
        child: Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: glow ? Colors.white : Colors.transparent,
              width: 3,
            ),
          ),
          color: i == shownCurrent && !game.gameOver
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: ListTile(
            dense: true,
            title: Text(game.players[i].name),
            subtitle: Text(_tilesText(
                shownTiles[i], i == shownTrangIdx ? shownTrangLabel : '')),
            trailing: Text('${shownScores[i]} điểm',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }

  Widget _bowl() => Container(
        width: 270,
        height: 270,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            colors: [Color(0xFFF5F5F5), Color(0xFFBCAAA4)],
          ),
          border: Border.all(color: const Color(0xFF5D4037), width: 8),
        ),
        child: Center(
          child: SizedBox(
            width: 176,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (var i = 0; i < 6; i++)
                  Transform.rotate(angle: angles[i], child: DieFace(faces[i])),
              ],
            ),
          ),
        ),
      );

  Widget _messageBox() => SizedBox(
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
      );

  @override
  Widget build(BuildContext context) {
    final myTurn = !rolling && !game.gameOver && !game.currentPlayer.isBot;
    return Scaffold(
      appBar: AppBar(title: const Text('Xăm Hường')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              _bank(),
              const SizedBox(height: 12),
              _bowl(),
              const SizedBox(height: 12),
              _messageBox(),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: game.gameOver
                    ? () => setState(_newGame)
                    : (myTurn ? _takeTurn : null),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
                  child: Text(game.gameOver ? 'Chơi lại' : 'Gieo',
                      style: const TextStyle(fontSize: 22)),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: game.gameOver ? _showResult : _togglePause,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 13),
                ),
                icon: Icon(
                  game.gameOver
                      ? Icons.emoji_events
                      : (paused ? Icons.play_arrow : Icons.pause),
                  size: 18,
                ),
                label: Text(game.gameOver
                    ? 'Xem kết quả'
                    : (paused ? 'Tiếp tục' : 'Tạm dừng')),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < game.players.length; i++)
                _playerCard(i),
            ],
          ),
        ),
      ),
    );
  }
}

class DieFace extends StatelessWidget {
  final int value;
  const DieFace(this.value, {super.key});

  // Pip positions on a 3x3 grid (row-major, 0..8).
  static const _pips = {
    1: [4],
    2: [0, 8],
    3: [0, 4, 8],
    4: [0, 2, 6, 8],
    5: [0, 2, 4, 6, 8],
    6: [0, 2, 3, 5, 6, 8],
  };

  @override
  Widget build(BuildContext context) {
    final color = isRed(value) ? Colors.red.shade700 : Colors.black87;
    return Container(
      width: 52,
      height: 52,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
      ),
      child: GridView.count(
        crossAxisCount: 3,
        physics: const NeverScrollableScrollPhysics(),
        children: List.generate(
          9,
          (i) => _pips[value]!.contains(i)
              ? Center(
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                )
              : const SizedBox(),
        ),
      ),
    );
  }
}
