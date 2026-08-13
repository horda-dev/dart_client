import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:horda_core/horda_core.dart';
import 'package:logging/logging.dart';
import 'system.dart';

final _logger = Logger('QuerySynchronizer');

/// A single in-flight query tracked by [QuerySynchronizer].
///
/// Returned by [QuerySynchronizer.register] and passed back to
/// [QuerySynchronizer.release] by the same caller that started the query.
/// Holding the instance is what identifies the query, so concurrent queries
/// sharing a [QueryDef] never resolve each other.
class InFlightQuery {
  InFlightQuery._(this.entityId, this.def);

  final EntityId entityId;

  final QueryDef def;

  final _completer = Completer<void>();

  /// Completes once this query has been finalized or released.
  Future<void> get done => _completer.future;

  bool get isDone => _completer.isCompleted;

  @override
  String toString() => 'InFlightQuery($entityId, ${def.entityName})';
}

/// Identifier for a query based on its QueryDef structure.
///
/// Used to test whether two queries subscribe to overlapping views.
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
  /// In-flight queries, in registration order.
  ///
  /// Queries are identified by instance rather than by [QueryDef], because the
  /// same query structure is routinely in flight for several entities at once.
  final _inFlight = <InFlightQuery>[];

  /// Registers a query as in-flight.
  ///
  /// This should be called at the start of `queryAndSubscribe()` before
  /// the server call is made.
  ///
  /// Returns the handle that the caller must pass back to [release] once the
  /// query has been finalized or has failed.
  InFlightQuery register(EntityId entityId, QueryDef def) {
    final query = InFlightQuery._(entityId, def);

    _inFlight.add(query);

    _logger.fine(
      'Registered in-flight query: $query with ${def.views.length} views',
    );

    return query;
  }

  /// Waits for all in-flight queries that intersect with [def] to complete.
  ///
  /// This should be called at the start of `unsubscribeViews()` before
  /// decrementing ref counts to ensure intersecting queries have completed
  /// their subscription setup.
  ///
  /// Two queries intersect if they share any common view keys (entityName/viewName).
  /// Entity ids are deliberately not compared: a single unsubscribe can cover
  /// child hosts of many entities, so matching stays on view structure alone.
  ///
  /// [def] - The QueryDef to check for intersections
  Future<void> waitForQuery(QueryDef def) async {
    final target = _QueryIdentifier(def);

    // Find all in-flight queries that intersect with this QueryDef
    final intersecting = _inFlight
        .where((query) => _QueryIdentifier(query.def).intersects(target))
        .toList();

    if (intersecting.isEmpty) {
      return;
    }

    _logger.info(
      'Deferring unsubscribe for ${def.entityName}, '
      '${intersecting.length} intersecting queries in flight',
    );

    // Wait for all intersecting queries to complete
    await Future.wait(intersecting.map((query) => query.done));

    _logger.info(
      'Intersecting queries completed for ${def.entityName}, '
      'proceeding with unsubscribe',
    );
  }

  /// Marks [query] as no longer in flight and releases any waiting unsubscribe
  /// operations that were deferred on it.
  ///
  /// Safe to call more than once, so callers can release in a `finally` block
  /// without checking whether the query already finalized.
  void release(InFlightQuery query) {
    if (!query.isDone) {
      query._completer.complete();
      _logger.fine('Query $query finalized');
    }

    _inFlight.remove(query);
  }

  /// Returns the number of in-flight queries.
  ///
  /// This is primarily for testing and debugging.
  @visibleForTesting
  int get inFlightCount => _inFlight.length;
}
