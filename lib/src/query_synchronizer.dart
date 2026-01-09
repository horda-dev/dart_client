import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:horda_core/horda_core.dart';
import 'package:logging/logging.dart';
import 'system.dart';

final _logger = Logger('QuerySynchronizer');

/// Identifier for a query based on its QueryDef structure.
///
/// Used as a key in the in-flight queries map to uniquely identify
/// and compare queries based on their definition.
class _QueryIdentifier {
  _QueryIdentifier(this.def);

  final QueryDef def;

  /// Returns true if this query's QueryDef intersects with [other].
  ///
  /// Two QueryDefs intersect if they subscribe to any common view keys.
  /// A view key is the combination of entityName/viewName.
  /// This check is recursive for nested queries in RefQueryDef and ListQueryDef.
  bool intersects(_QueryIdentifier other) {
    final thisViewKeys = _collectViewKeys(def);
    final otherViewKeys = _collectViewKeys(other.def);

    // Check if there's any common view key
    for (var key in thisViewKeys) {
      if (otherViewKeys.contains(key)) {
        return true;
      }
    }

    return false;
  }

  /// Recursively collects all view keys (entityName/viewName) from a QueryDef.
  static Set<String> _collectViewKeys(QueryDef def) {
    final keys = <String>{};

    for (var entry in def.views.entries) {
      final viewName = entry.key;
      final viewDef = entry.value;

      // Add the view key for this level
      keys.add('${def.entityName}/$viewName');

      // Recursively collect keys from nested queries
      if (viewDef is RefQueryDef) {
        keys.addAll(_collectViewKeys(viewDef.query));
      } else if (viewDef is ListQueryDef) {
        keys.addAll(_collectViewKeys(viewDef.query));
      }
    }

    return keys;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _QueryIdentifier) return false;

    return _queryDefEquals(def, other.def);
  }

  @override
  int get hashCode => _queryDefHash(def);

  /// Deep equality check for QueryDef objects.
  static bool _queryDefEquals(QueryDef a, QueryDef b) {
    if (a.entityName != b.entityName) return false;
    if (a.views.length != b.views.length) return false;

    for (var entry in a.views.entries) {
      final otherView = b.views[entry.key];
      if (otherView == null || !_viewQueryDefEquals(entry.value, otherView)) {
        return false;
      }
    }

    return true;
  }

  /// Deep hash code for QueryDef objects.
  static int _queryDefHash(QueryDef def) {
    var hash = def.entityName.hashCode;
    for (var entry in def.views.entries) {
      hash ^= entry.key.hashCode ^ _viewQueryDefHash(entry.value);
    }
    return hash;
  }

  /// Equality check for ViewQueryDef objects.
  static bool _viewQueryDefEquals(ViewQueryDef a, ViewQueryDef b) {
    if (a.runtimeType != b.runtimeType) return false;

    if (a is ValueQueryDef && b is ValueQueryDef) {
      return true;
    } else if (a is CounterQueryDef && b is CounterQueryDef) {
      return true;
    } else if (a is RefQueryDef && b is RefQueryDef) {
      return _queryDefEquals(a.query, b.query) && _listEquals(a.attrs, b.attrs);
    } else if (a is ListQueryDef && b is ListQueryDef) {
      return _queryDefEquals(a.query, b.query) &&
          _listEquals(a.attrs, b.attrs) &&
          a.startAfter == b.startAfter &&
          a.endBefore == b.endBefore &&
          a.limit == b.limit;
    }

    return false;
  }

  /// Hash code for ViewQueryDef objects.
  static int _viewQueryDefHash(ViewQueryDef def) {
    var hash = def.runtimeType.hashCode;

    if (def is RefQueryDef) {
      hash ^= _queryDefHash(def.query);
      for (var attr in def.attrs) {
        hash ^= attr.hashCode;
      }
    } else if (def is ListQueryDef) {
      hash ^= _queryDefHash(def.query);
      for (var attr in def.attrs) {
        hash ^= attr.hashCode;
      }
      hash ^= def.startAfter.hashCode;
      hash ^= def.endBefore.hashCode;
      hash ^= def.limit.hashCode;
    }

    return hash;
  }

  /// Helper to compare lists for equality.
  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Temporary synchronization mechanism to prevent client-server desync between
/// query subscription and unsubscription during widget remounting.
///
/// This class tracks in-flight queries and allows deferring unsubscribe operations
/// until in-flight query has completed and finalized. Query finalization means:
/// 1. We received the query result
/// 2. We incremented view sub counters based on the query result
///
/// This ensures ref counts are incremented before any decrements from unmounting widget elements,
/// so no breaking unsubscribe view requests will be sent.
///
/// TODO: This fixes the problem described in https://github.com/horda-dev/dart_client/issues/24#issuecomment-3646627507
///
/// To remove:
/// 1. Remove calls to synchronizer methods
/// 2. Remove [HordaClientSystem._querySynchronizer] field
/// 3. Delete this file
class QuerySynchronizer {
  /// Tracks in-flight queries to prevent race conditions during widget remounting.
  /// - Key: _QueryIdentifier (based on QueryDef structure)
  /// - Value: Completer that completes when query finalization is done
  final _inFlightQueries = <_QueryIdentifier, Completer<void>>{};

  /// Registers a query as in-flight.
  ///
  /// This should be called at the start of `queryAndSubscribe()` before
  /// the server call is made.
  ///
  /// [def] - The QueryDef being executed
  /// Returns the completer that will be completed when the query is finalized
  Completer<void> registerQuery(QueryDef def) {
    final completer = Completer<void>();
    final identifier = _QueryIdentifier(def);
    _inFlightQueries[identifier] = completer;
    _logger.fine(
      'Registered in-flight query: ${def.entityName} with ${def.views.length} views',
    );
    return completer;
  }

  /// Waits for all in-flight queries that intersect with [def] to complete.
  ///
  /// This should be called at the start of `unsubscribeViews()` before
  /// decrementing ref counts to ensure intersecting queries have completed
  /// their subscription setup.
  ///
  /// Two queries intersect if they share any common view keys (entityName/viewName).
  ///
  /// [def] - The QueryDef to check for intersections
  Future<void> waitForQuery(QueryDef def) async {
    final targetIdentifier = _QueryIdentifier(def);

    // Find all in-flight queries that intersect with this QueryDef
    final intersectingCompleters = _inFlightQueries.entries
        .where((e) => e.key.intersects(targetIdentifier))
        .map((e) => e.value);

    if (intersectingCompleters.isEmpty) {
      return;
    }

    _logger.info(
      'Deferring unsubscribe for ${def.entityName}, '
      '${intersectingCompleters.length} intersecting queries in flight',
    );

    // Wait for all intersecting queries to complete
    await Future.wait(
      intersectingCompleters.map((c) => c.future),
    );

    _logger.info(
      'Intersecting queries completed for ${def.entityName}, '
      'proceeding with unsubscribe',
    );
  }

  /// Marks a query as complete and allows waiting unsubscribe operations to proceed.
  ///
  /// This should be called in `finalizeQuerySubscriptions()` after ref counts
  /// have been incremented.
  ///
  /// [def] - The QueryDef that has been finalized
  void completeQuery(QueryDef def) {
    final identifier = _QueryIdentifier(def);
    final completer = _inFlightQueries[identifier];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
      _inFlightQueries.remove(identifier);
      _logger.fine('Query ${def.entityName} finalized');
    }
  }

  /// Cleans up a query in case of errors during query execution.
  ///
  /// This ensures the completer is completed even if query execution fails,
  /// preventing deadlocks in waiting unsubscribe operations.
  ///
  /// [def] - The QueryDef being cleaned up
  /// [completer] - The completer returned from registerQuery
  void cleanupQuery(QueryDef def, Completer<void> completer) {
    // Complete the completer if not already done
    if (!completer.isCompleted) {
      completer.complete();
    }

    final identifier = _QueryIdentifier(def);
    // Only remove if we're still the current completer (handles overwrites)
    if (_inFlightQueries[identifier] == completer) {
      _inFlightQueries.remove(identifier);
      _logger.fine('Cleaned up query ${def.entityName}');
    }
  }

  /// Returns true if a query is currently in-flight.
  ///
  /// This is primarily for testing and debugging.
  @visibleForTesting
  bool isQueryInFlight(QueryDef def) {
    final identifier = _QueryIdentifier(def);
    return _inFlightQueries.containsKey(identifier);
  }

  /// Returns the number of in-flight queries.
  ///
  /// This is primarily for testing and debugging.
  @visibleForTesting
  int get inFlightCount => _inFlightQueries.length;
}
