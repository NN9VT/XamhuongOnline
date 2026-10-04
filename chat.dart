// Online chat widgets: flying messages (弹幕), a floating chat button and the
// input sheet.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

class _Fly {
  final String text;
  final int lane;
  final double width;
  final AnimationController c;
  _Fly(this.text, this.lane, this.width, this.c);
}

/// Messages that fly from right to left. Call `add` through a
/// GlobalKey<DanmakuLayerState>. Wrap it in IgnorePointer so touches pass through.
class DanmakuLayer extends StatefulWidget {
  final bool enabled;
  final double topOffset;
  const DanmakuLayer({
    super.key,
    required this.enabled,
    required this.topOffset,
  });

  @override
  State<DanmakuLayer> createState() => DanmakuLayerState();
}

class DanmakuLayerState extends State<DanmakuLayer>
    with TickerProviderStateMixin {
  static const int lanes = 4;
  static const double laneHeight = 32;
  static const double speed = 90; // pixels per second
  static const int maxOnScreen = 10;
  static const TextStyle style = TextStyle(
    fontSize: 16,
    color: Colors.white,
    shadows: [
      Shadow(blurRadius: 3, color: Colors.black),
      Shadow(blurRadius: 2, color: Colors.black, offset: Offset(1, 1)),
    ],
  );

  final _rng = Random();
  final List<_Fly> _flies = [];
  final List<String> _queue = [];
  final List<DateTime> _laneFree =
      List.filled(lanes, DateTime.fromMillisecondsSinceEpoch(0));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _drain());
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final f in _flies) {
      f.c.dispose();
    }
    super.dispose();
  }

  void add(String text) {
    if (!widget.enabled) return;
    if (_queue.length < 20) _queue.add(text);
    _drain();
  }

  double _measure(String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _drain() {
    if (!mounted) return;
    final screenW = MediaQuery.of(context).size.width;
    while (_queue.isNotEmpty && _flies.length < maxOnScreen) {
      final now = DateTime.now();
      final free = [
        for (var i = 0; i < lanes; i++)
          if (!_laneFree[i].isAfter(now)) i,
      ];
      if (free.isEmpty) return;
      final lane = free[_rng.nextInt(free.length)];
      final text = _queue.removeAt(0);
      final w = _measure(text);
      final ms = ((screenW + w) / speed * 1000).round();
      final c = AnimationController(
          vsync: this, duration: Duration(milliseconds: ms));
      final fly = _Fly(text, lane, w, c);
      // The lane is free again once this message has cleared the right edge.
      _laneFree[lane] =
          now.add(Duration(milliseconds: ((w + 48) / speed * 1000).round()));
      c.addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _flies.remove(fly));
          WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
        }
      });
      setState(() => _flies.add(fly));
      c.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Stack(
      children: [
        for (final f in _flies)
          AnimatedBuilder(
            animation: f.c,
            builder: (_, __) => Positioned(
              left: w - f.c.value * (w + f.width),
              top: widget.topOffset + f.lane * laneHeight,
              width: f.width + 6,
              child: Text(f.text, maxLines: 1, softWrap: false, style: style),
            ),
          ),
      ],
    );
  }
}

/// Translucent floating button. Touch it to light it up, long-press and drag
/// to move it. Position is given and reported as fractions (0..1).
class ChatButton extends StatefulWidget {
  final Offset? initial;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMoved;
  const ChatButton({
    super.key,
    required this.initial,
    required this.onTap,
    required this.onMoved,
  });

  @override
  State<ChatButton> createState() => _ChatButtonState();
}

class _ChatButtonState extends State<ChatButton> {
  static const double size = 52;
  Offset? _drag; // pixel position while dragging
  Offset _dragStart = Offset.zero;
  bool _bright = false;
  Timer? _fade;

  void _wake() {
    _fade?.cancel();
    setState(() => _bright = true);
  }

  void _sleepSoon() {
    _fade?.cancel();
    _fade = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _bright = false);
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final maxX = max(0.0, box.maxWidth - size);
      final maxY = max(0.0, box.maxHeight - size);
      final f = widget.initial ?? const Offset(1, 0.5);
      final pos = _drag ?? Offset(f.dx * maxX, f.dy * maxY);
      return Stack(
        children: [
          Positioned(
            left: pos.dx,
            top: pos.dy,
            child: GestureDetector(
              onTapDown: (_) => _wake(),
              onTapUp: (_) => _sleepSoon(),
              onTapCancel: _sleepSoon,
              onTap: widget.onTap,
              onLongPressStart: (_) {
                _wake();
                _dragStart = pos;
                setState(() => _drag = pos);
              },
              onLongPressMoveUpdate: (d) {
                final p = _dragStart + d.offsetFromOrigin;
                setState(() => _drag = Offset(
                      p.dx.clamp(0.0, maxX),
                      p.dy.clamp(0.0, maxY),
                    ));
              },
              onLongPressEnd: (_) {
                final p = _drag;
                if (p != null && maxX > 0 && maxY > 0) {
                  widget.onMoved(Offset(p.dx / maxX, p.dy / maxY));
                }
                setState(() => _drag = null);
                _sleepSoon();
              },
              child: AnimatedOpacity(
                opacity: _bright ? 1.0 : 0.35,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white70),
                  ),
                  child: const Icon(Icons.chat_bubble_outline,
                      color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// Input sheet. onSend returns an error text, or null when the message went out.
class ChatSheet extends StatefulWidget {
  final String? Function(String text) onSend;
  final bool danmakuOn;
  final ValueChanged<bool> onToggle;
  const ChatSheet({
    super.key,
    required this.onSend,
    required this.danmakuOn,
    required this.onToggle,
  });

  @override
  State<ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<ChatSheet> {
  final _c = TextEditingController();
  String? _error;
  late bool _on = widget.danmakuOn;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _send() {
    final err = widget.onSend(_c.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _c,
            autofocus: true,
            maxLength: 60,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              hintText: 'Nhập tin nhắn...',
              errorText: _error,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.send),
                onPressed: _send,
              ),
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Hiện tin bay'),
            value: _on,
            onChanged: (v) {
              setState(() => _on = v);
              widget.onToggle(v);
            },
          ),
        ],
      ),
    );
  }
}
