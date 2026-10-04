// Xăm hường - game controller (turns, stealing, end of game).
// Depends on xam_huong_engine.dart. Pure Dart, no Flutter.

import 'dart:math';
import 'xam_huong_engine.dart';

class Player {
  String name;
  bool isBot;
  final Map<Tile, int> tiles = {for (final t in Tile.values) t: 0};

  /// Set by Lục Phú Hường (382); otherwise the score comes from the tiles.
  int? fixedScore;

  Player(this.name, {this.isBot = false});

  int get score =>
      fixedScore ??
      tiles.entries.fold(0, (s, e) => s + e.key.points * e.value);

  void add(Map<Tile, int> got) {
    got.forEach((t, n) => tiles[t] = tiles[t]! + n);
  }

  Map<Tile, int> clear() {
    final old = Map<Tile, int>.from(tiles);
    for (final t in Tile.values) {
      tiles[t] = 0;
    }
    return old;
  }
}

class TurnOutcome {
  final Player player;
  final RollResult roll;
  final Award award;
  final List<Player> victims; // players who lost a Trạng this turn
  final String? note; // Giảm giá info for the UI
  final int stolenPoints;
  const TurnOutcome(this.player, this.roll, this.award,
      {this.victims = const [], this.note, this.stolenPoints = 0});
}

class XamHuongGame {
  final List<Player> players;
  final Bank bank = Bank();
  final Random _rng;

  int current = 0;
  bool gameOver = false;

  /// Who holds Trạng Nguyên and how (colour, rank), for "cướp Trạng".
  Player? trangHolder;
  Trang? trangInfo;

  /// Automatic Giảm giá, only when Trạng Nguyên is the last tile on the table:
  /// 0 = off, 1 = Tam Hường Phân Song can take it, 2 = any Bảng Nhãn result.
  int discountStage = 0;
  int _failedTurns = 0;

  XamHuongGame(this.players, {Random? rng}) : _rng = rng ?? Random() {
    assert(players.length >= 2 && players.length <= 8);
  }

  Player get currentPlayer => players[current];

  /// A player who left: renamed "Bot <name>" and played by the host from now on.
  void convertToBot(int i) {
    final p = players[i];
    if (p.isBot) return;
    p.name = 'Bot ${p.name}';
    p.isBot = true;
  }

  List<Player> get winners {
    final best = players.map((p) => p.score).reduce(max);
    return players.where((p) => p.score == best).toList();
  }

  /// The current player rolls and the result is applied.
  TurnOutcome playTurn() {
    assert(!gameOver);
    final p = currentPlayer;
    final wasOnlyTrang = bank.onlyTrangAnhLeft;
    final roll = evaluateRoll(rollDice(_rng));
    var award = const Award({}, false);
    final notes = <String>[];
    final victims = <Player>[];
    var stolenPoints = 0;

    if (roll.winEverything || roll.winAllRemaining) {
      // Lục Phú (Hường): take every tile, everyone else drops to 0.
      for (final other in players) {
        if (other != p) p.add(other.clear());
      }
      award = bank.takeAll();
      p.add(award.tiles);
      if (roll.winEverything) p.fixedScore = 382;
      trangHolder = p;
      trangInfo = null;
    } else if (roll.tiles.isNotEmpty) {
      final wanted = List<Tile>.of(roll.tiles);

      // Giảm giá: the last Trạng Nguyên gets easier to take.
      if (wasOnlyTrang) {
        if (discountStage >= 1 && roll.names.contains('Tam Hường Phân Song')) {
          wanted
            ..clear()
            ..add(Tile.trangAnh);
        }
        if (discountStage >= 2 && wanted.contains(Tile.trangEm)) {
          wanted
            ..clear()
            ..add(Tile.trangAnh);
        }
      }

      // Cướp Trạng: same colour only, higher rank only.
      final tr = roll.trang;
      final holder = trangHolder;
      final info = trangInfo;
      if (tr != null &&
          wanted.contains(Tile.trangAnh) &&
          bank.stock[Tile.trangAnh] == 0 &&
          holder != null &&
          holder != p &&
          info != null &&
          holder.tiles[Tile.trangAnh]! > 0 &&
          (info.kind == tr.kind || tr.beatsAnyColor) &&
          tr.rank > info.rank) {
        holder.tiles[Tile.trangAnh] = holder.tiles[Tile.trangAnh]! - 1;
        p.tiles[Tile.trangAnh] = p.tiles[Tile.trangAnh]! + 1;
        trangHolder = p;
        trangInfo = tr;
        wanted.remove(Tile.trangAnh);
        stolenPoints += Tile.trangAnh.points;
        if (!victims.contains(holder)) victims.add(holder);
      }

      // Ngũ Hường also takes missing Bảng Nhãn from other players.
      if (roll.stealsTrangEm) {
        var missing = wanted.where((t) => t == Tile.trangEm).length -
            bank.stock[Tile.trangEm]!;
        for (final other in players) {
          while (missing > 0 && other != p && other.tiles[Tile.trangEm]! > 0) {
            other.tiles[Tile.trangEm] = other.tiles[Tile.trangEm]! - 1;
            p.tiles[Tile.trangEm] = p.tiles[Tile.trangEm]! + 1;
            wanted.remove(Tile.trangEm);
            stolenPoints += Tile.trangEm.points;
            if (!victims.contains(other)) victims.add(other);
            missing--;
          }
        }
      }

      award = bank.award(wanted);
      p.add(award.tiles);

      if ((award.tiles[Tile.trangAnh] ?? 0) > 0) {
        trangHolder = p;
        trangInfo = tr; // null when taken through Giảm giá
      }
    }

    // Automatic Giảm giá: count turns where nobody took the last tile.
    if (wasOnlyTrang && bank.onlyTrangAnhLeft) {
      _failedTurns++;
      if (_failedTurns >= 3 * players.length && discountStage < 2) {
        discountStage++;
        _failedTurns = 0;
        notes.add('Giảm giá: Trạng Nguyên dễ lấy hơn!');
      }
    } else if (!bank.onlyTrangAnhLeft) {
      _failedTurns = 0;
    }

    if (award.gameOver || bank.isEmpty) gameOver = true;
    current = (current + 1) % players.length;
    return TurnOutcome(
      p,
      roll,
      award,
      victims: victims,
      note: notes.isEmpty ? null : notes.join('\n'),
      stolenPoints: stolenPoints,
    );
  }
}
