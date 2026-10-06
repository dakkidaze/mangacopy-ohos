/// 章节边界二次确认换章（对齐原生 PagesManager isEndL/isEndR）。
enum ChapterEdgeOutcome { confirmNeeded, openChapter, atEnd }

class ChapterEdgeGuard {
  bool _hintNext = false;
  bool _hintPrev = false;

  ChapterEdgeOutcome onEdge(bool goNext, {required bool hasAdjacent}) {
    if (!hasAdjacent) {
      return ChapterEdgeOutcome.atEnd;
    }
    if (goNext ? _hintNext : _hintPrev) {
      if (goNext) {
        _hintNext = false;
      } else {
        _hintPrev = false;
      }
      return ChapterEdgeOutcome.openChapter;
    }
    if (goNext) {
      _hintNext = true;
    } else {
      _hintPrev = true;
    }
    return ChapterEdgeOutcome.confirmNeeded;
  }

  void clear() {
    _hintNext = false;
    _hintPrev = false;
  }

  void clearSide(bool goNext) {
    if (goNext) {
      _hintNext = false;
    } else {
      _hintPrev = false;
    }
  }

  /// 诊断只读：是否已提示「再次滑动/按下」以切下一章。
  bool get currentlyHintingNext => _hintNext;

  /// 诊断只读：是否已提示「再次滑动/按下」以切上一章。
  bool get currentlyHintingPrevious => _hintPrev;

  /// 不改变状态的快照，供 debug 日志使用。
  Map<String, bool> debugSnapshot() => {
    'currentlyHintingNext': _hintNext,
    'currentlyHintingPrevious': _hintPrev,
  };
}

/// 一次 pointer 手势内只放行一次越界计数，避免同一次拖动的连续 overscroll 重复触发。
class EdgeGestureGate {
  bool _consumed = true;

  void beginGesture() {
    _consumed = false;
  }

  bool allow() {
    if (_consumed) return false;
    _consumed = true;
    return true;
  }
}

/// 越界 overscroll 是否计为一次章节边界手势。
/// 必须先确认方向对应边界，再消耗 [gate]，避免方向抖动白白吞掉本手势配额。
bool tryAcceptEdgeOverscroll({
  required double overscroll,
  required bool Function(bool towardEnd) atChapterEdge,
  required EdgeGestureGate gate,
  double minAbs = 6,
}) {
  if (overscroll.abs() < minAbs) return false;
  final towardEnd = overscroll > 0;
  if (!atChapterEdge(towardEnd)) return false;
  return gate.allow();
}
