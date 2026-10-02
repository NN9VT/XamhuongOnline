// Widgets used by the online screens.

import 'package:flutter/material.dart';

import 'xam_huong_engine.dart';

/// Tile names as shown on the table and on player cards.
const Map<Tile, String> tileNames = {
  Tile.trangAnh: 'Trạng Nguyên',
  Tile.trangEm: 'Bảng Nhãn',
  Tile.tamHuong: 'Hội Nguyên',
  Tile.tuTu: 'Tiến Sỹ',
  Tile.nhiHuong: 'Cử Nhân',
  Tile.nhatHuong: 'Tú Tài',
};

String tilesText(Map<Tile, int> m, String trangLabel) {
  final s = m.entries.where((e) => e.value > 0).map((e) {
    final extra = (e.key == Tile.trangAnh && trangLabel.isNotEmpty)
        ? ' ($trangLabel)'
        : '';
    return '${e.value}x ${tileNames[e.key]}$extra';
  }).join(', ');
  return s.isEmpty ? 'Chưa có thẻ' : s;
}

class BankGrid extends StatelessWidget {
  final Map<Tile, int> stock;
  final Set<Tile> glowing;
  final int discount;
  const BankGrid({
    super.key,
    required this.stock,
    required this.glowing,
    required this.discount,
  });

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return GridView.builder(
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
        final tint = (t == Tile.trangAnh && discount > 0)
            ? const Color(0x24FFFFFF)
            : Colors.transparent;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Color.alphaBlend(tint, bg), // opaque: glow stays on border
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
              '${tileNames[t]} (${t.points}đ) ×${stock[t] ?? 0}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }
}

class DiceBowl extends StatelessWidget {
  final List<int> faces;
  final List<double> angles;
  const DiceBowl({super.key, required this.faces, required this.angles});

  @override
  Widget build(BuildContext context) => Container(
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
                  Transform.rotate(angle: angles[i], child: Die(faces[i])),
              ],
            ),
          ),
        ),
      );
}

class PlayerTile extends StatelessWidget {
  final String name;
  final String tiles;
  final int score;
  final bool current;
  final bool glow;
  const PlayerTile({
    super.key,
    required this.name,
    required this.tiles,
    required this.score,
    required this.current,
    required this.glow,
  });

  @override
  Widget build(BuildContext context) {
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
          color:
              current ? Theme.of(context).colorScheme.primaryContainer : null,
          child: ListTile(
            dense: true,
            title: Text(name),
            subtitle: Text(tiles),
            trailing: Text('$score điểm',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }
}

class Die extends StatelessWidget {
  final int value;
  const Die(this.value, {super.key});

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
