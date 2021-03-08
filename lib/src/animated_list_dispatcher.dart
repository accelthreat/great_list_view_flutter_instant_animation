import 'dart:async';

import 'package:diffutil_dart/diffutil.dart';
import 'package:worker_manager/worker_manager.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'animated_sliver_list.dart';

typedef AnimatedListDiffItemBuilder<T> = Widget Function(
    BuildContext context, T list, int index, AnimatedListBuildType buildType);

/// A derivated version of this class has to be implemented to tell [AnimatedListDiffDispatcher]
/// how compare items of two lists in order to dispatch to the [AnimatedListController]
/// the differences.
abstract class AnimatedListDiffComparator<T> {
  /// Compares the [indexA] of the [listA] with the [indexB] of the [listB] and returns
  /// `true` is they are the same item. Usually, the "id" of the item is compared here.
  bool sameItem(T listA, int indexA, T listB, int indexB);

  /// Compares the [indexA] of [listA] with the [indexB] of [listB] and returns
  /// `true` is they have the same content. This method is called after [sameItem]
  /// returned `true`, so this method tells if the same item has changed in its content,
  /// if so a changing notification will be sent to the controller.
  bool sameContent(T listA, int indexA, T listB, int indexB);

  /// Returns the length of the [list].
  int lengthOf(T list);
}

/// This class takes an initial list that can be replaced with a new one through
/// the [dispatchNewList] method.
/// When a new list is provided, the `Myers` algorithm runs in a separated `Isolate`
/// to detect the differences. These differences will be dispatched to the
/// [animatedListController] provided.
/// An [itemBuilder] has to be provided to build replaced and changed items (as required
/// by [AnimatedListController.notifyChangedRange], [AnimatedListController.notifyReplacedRange]
/// and [AnimatedListController.notifyRemovedRange] methods).
/// The two lists are compared using the [comparator] provided.
///
/// The current list to be passed to the [AnimatedSliverList] can be retrieved from the
/// [currentList] getter.
class AnimatedListDiffDispatcher<T> {
  final AnimatedListController animatedListController;
  final AnimatedListDiffItemBuilder<T> itemBuilder;
  final AnimatedListDiffComparator<T> comparator;

  T _currentList, _oldList, _processingList;

  AnimatedListDiffDispatcher({
    @required this.animatedListController,
    @required this.itemBuilder,
    @required this.comparator,
    @required T initialList,
  }) : _currentList = initialList;

  /// Replaces the current list with the new one. Differences are calculated and then dispatched
  /// to the coontroller.
  void dispatchNewList(final T newList) async {
    _processingList = newList;

    var dr = await _computeDiffs(_currentList, newList);

    if (dr == null || newList != _processingList || _processingList == null) {
      return; // discard result
    }

    _oldList = _currentList;
    _currentList = _processingList;
    _processingList = null;

    final oldList = _oldList;

    dr._dispatchUpdatesTo(
      onInsert: (position, count) {
        animatedListController.notifyInsertedRange(position, count);
      },
      onChange: (position, count) {
        animatedListController.notifyChangedRange(position, count,
            (context, index) {
          return itemBuilder.call(context, oldList, position + index,
              AnimatedListBuildType.CHANGING);
        });
      },
      onRemove: (position, count) {
        animatedListController.notifyRemovedRange(position, count,
            (context, index) {
          return itemBuilder.call(context, oldList, position + index,
              AnimatedListBuildType.REMOVING);
        });
      },
      onReplace: (position, removeCount, insertCount) {
        animatedListController.notifyReplacedRange(
            position, removeCount, insertCount, (context, index) {
          return itemBuilder.call(context, oldList, position + index,
              AnimatedListBuildType.REMOVING);
        });
      },
    );

    animatedListController.dispatchChanges();
  }

  /// Returns the current list to be passed to the [AnimatedSliverList].
  T get currentList => _currentList;

  final List<Cancelable<_DiffResultDispatcher>> _pendings = [];

  Future<_DiffResultDispatcher> _computeDiffs(
      final T oldList, final T newList) async {
    while (_pendings.isNotEmpty) {
      _pendings.first.cancel();
      // ignore: unawaited_futures
      _pendings.removeAt(0);
    }

    var task = Executor().execute<T, T, AnimatedListDiffComparator<T>, Null,
            _DiffResultDispatcher>(
        arg1: oldList, arg2: newList, arg3: comparator, fun3: _dispatch);

    _pendings.add(task);

    try {
      var r = await task;
      _pendings.remove(task);
      return r;
    } catch (e) {
      _pendings.remove(task);
    }

    return null;
  }
}

FutureOr<_DiffResultDispatcher> _dispatch<E>(
    E oldList, E newList, AnimatedListDiffComparator<E> comparator) async {
  // await new Future.delayed(const Duration(seconds: 2));
  return _DiffResultDispatcher(calculateDiff(
    _ListDiffDelegate<E>(
      oldList,
      newList,
      comparator.sameContent,
      comparator.sameItem,
      comparator.lengthOf,
    ),
    detectMoves: false,
  ));
}

class _ListDiffDelegate<T> implements DiffDelegate {
  final T oldList;
  final T newList;
  final bool Function(T, int, T, int) _areContentsTheSame;
  final bool Function(T, int, T, int) _areItemsTheSame;
  final int Function(T) _listLength;

  _ListDiffDelegate(this.oldList, this.newList, this._areContentsTheSame,
      this._areItemsTheSame, this._listLength);

  @override
  bool areContentsTheSame(int oldItemPosition, int newItemPosition) {
    return _areContentsTheSame.call(
        oldList, oldItemPosition, newList, newItemPosition);
  }

  @override
  bool areItemsTheSame(int oldItemPosition, int newItemPosition) {
    return _areItemsTheSame.call(
        oldList, oldItemPosition, newList, newItemPosition);
  }

  @override
  Object getChangePayload(int oldItemPosition, int newItemPosition) {
    return null;
  }

  @override
  int getNewListSize() => _listLength(newList);

  @override
  int getOldListSize() => _listLength(oldList);
}

enum _OperationType {
  INSERT,
  REMOVE,
  REPLACE,
  CHANGE,
}

class _Operation {
  final _OperationType type;
  final int position, count1, count2;

  _Operation(
      {@required this.type,
      @required this.position,
      @required this.count1,
      this.count2});

  @override
  String toString() {
    if (type == _OperationType.REPLACE) {
      return '$typeToString $position ($count1,$count2)';
    } else {
      return '$typeToString $position ($count1)';
    }
  }

  String get typeToString {
    switch (type) {
      case _OperationType.INSERT:
        return 'INS';
      case _OperationType.REMOVE:
        return 'REM';
      case _OperationType.REPLACE:
        return 'REP';
      case _OperationType.CHANGE:
        return 'CHG';
      default:
        return null;
    }
  }
}

class _DiffResultDispatcher {
  int _removedPosition, _removedCount;
  final List<_Operation> _list = [];

  _DiffResultDispatcher(final DiffResult diffResult) {
    var upd = diffResult.getUpdates(batch: false);
    for (final u in upd) {
      u.when(
        change: (position, payload) {
          _pushPendingRemoved();
          _list.add(_Operation(
              type: _OperationType.CHANGE, position: position, count1: 1));
        },
        insert: (position, count) {
          if (position == _removedPosition) {
            _list.add(_Operation(
                type: _OperationType.REPLACE,
                position: position,
                count1: _removedCount,
                count2: count));
            _removedPosition = null;
          } else {
            _pushPendingRemoved();
            _list.add(_Operation(
                type: _OperationType.INSERT,
                position: position,
                count1: count));
          }
        },
        move: (from, to) {
          throw 'operation noy supported yet!';
        },
        remove: (position, count) {
          _pushPendingRemoved();
          _removedPosition = position;
          _removedCount = count;
        },
      );
    }

    _pushPendingRemoved();
  }

  @override
  String toString() => _list.toString();

  void _pushPendingRemoved() {
    if (_removedPosition != null) {
      _list.add(_Operation(
          type: _OperationType.REMOVE,
          position: _removedPosition,
          count1: _removedCount));
      _removedPosition = null;
    }
  }

  void _dispatchUpdatesTo(
      {void Function(int position, int count) onInsert,
      void Function(int position, int count) onRemove,
      void Function(int position, int removeCount, int insertCount) onReplace,
      void Function(int position, int count) onChange}) {
    for (final op in _list) {
      switch (op.type) {
        case _OperationType.INSERT:
          onInsert?.call(op.position, op.count1);
          break;
        case _OperationType.REMOVE:
          onRemove?.call(op.position, op.count1);
          break;
        case _OperationType.REPLACE:
          onReplace?.call(op.position, op.count1, op.count2);
          break;
        case _OperationType.CHANGE:
          onChange?.call(op.position, op.count1);
          break;
      }
    }
  }
}

//

typedef ListAnimatedListDiffItemBuilder<T> = Widget Function(
    BuildContext context,
    T element,
    int index,
    AnimatedListBuildType buildType);

/// A simplified [List] version of [AnimatedListDiffComparator].
abstract class ListAnimatedListDiffComparator<T> {
  bool sameItem(T elementA, T elementB);
  bool sameContent(T elementA, T elementB);
}

/// This class extends [AnimatedListDiffDispatcher] in order to handle easier the list
/// using a [List] object type.
class ListAnimatedListDiffDispatcher<T>
    extends AnimatedListDiffDispatcher<List<T>> {
  ListAnimatedListDiffDispatcher({
    @required AnimatedListController animatedListController,
    @required ListAnimatedListDiffItemBuilder<T> itemBuilder,
    @required List<T> currentList,
    @required ListAnimatedListDiffComparator<T> comparator,
  }) : super(
          animatedListController: animatedListController,
          initialList: currentList,
          itemBuilder: (BuildContext context, List<T> list, int index,
                  AnimatedListBuildType buildType) =>
              itemBuilder.call(context, list[index], index, buildType),
          comparator: _ListAnimatedListDiffComparatorDelegate<T>(comparator),
        );
}

class _ListAnimatedListDiffComparatorDelegate<T>
    extends AnimatedListDiffComparator<List<T>> {
  final ListAnimatedListDiffComparator<T> comparator;

  _ListAnimatedListDiffComparatorDelegate(this.comparator);

  @override
  bool sameItem(List<T> listA, int indexA, List<T> listB, int indexB) =>
      comparator.sameItem.call(listA[indexA], listB[indexB]);

  @override
  bool sameContent(List<T> listA, int indexA, List<T> listB, int indexB) =>
      comparator.sameContent.call(listA[indexA], listB[indexB]);

  @override
  int lengthOf(List<T> list) => list.length;
}
