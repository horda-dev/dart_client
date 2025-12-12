import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'system.dart';

final _logger = Logger('QuerySynchronizer');

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
/// 2. Optionally remove `queryKey` parameters if no longer needed:
///   - in [HordaClientSystem.queryAndSubscribe]
///   - in [HordaClientSystem.unsubscribeViews]
/// 3. Remove [HordaClientSystem._querySynchronizer] field
/// 4. Delete this file
class QuerySynchronizer {
  /// Tracks in-flight queries to prevent race conditions during widget remounting.
  /// - Key: query identifier in format "entityId/queryName"
  /// - Value: completer that completes when query finalization is done
  final _inFlightQueries = <String, Completer<void>>{};

  /// Registers a query as in-flight.
  ///
  /// This should be called at the start of `queryAndSubscribe()` before
  /// the server call is made.
  ///
  /// [queryKey] - Query identifier in format "entityId/queryName"
  /// Returns the completer that will be completed when the query is finalized
  Completer<void> registerQuery(String queryKey) {
    final completer = Completer<void>();
    _inFlightQueries[queryKey] = completer;
    _logger.fine('Registered in-flight query: $queryKey');
    return completer;
  }

  /// Waits for an in-flight query to complete if one exists.
  ///
  /// This should be called at the start of `unsubscribeViews()` before
  /// decrementing ref counts to ensure the query has completed its
  /// subscription setup.
  ///
  /// [queryKey] - Query identifier in format "entityId/queryName"
  Future<void> waitForQuery(String queryKey) async {
    final completer = _inFlightQueries[queryKey];
    if (completer != null) {
      _logger.info('Deferring unsubscribe for $queryKey, query in flight');
      await completer.future;
      _logger.info(
        'In-flight query completed for $queryKey, proceeding with unsubscribe',
      );
    }
  }

  /// Marks a query as complete and allows waiting unsubscribe operations to proceed.
  ///
  /// This should be called in `finalizeQuerySubscriptions()` after ref counts
  /// have been incremented.
  ///
  /// [queryKey] - Query identifier in format "entityId/queryName"
  void completeQuery(String queryKey) {
    final completer = _inFlightQueries[queryKey];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
      _inFlightQueries.remove(queryKey);
      _logger.fine('Query $queryKey finalized');
    }
  }

  /// Cleans up a query in case of errors during query execution.
  ///
  /// This ensures the completer is completed even if query execution fails,
  /// preventing deadlocks in waiting unsubscribe operations.
  ///
  /// [queryKey] - Query identifier in format "entityId/queryName"
  /// [completer] - The completer returned from registerQuery
  void cleanupQuery(String queryKey, Completer<void> completer) {
    // Complete the completer if not already done
    if (!completer.isCompleted) {
      completer.complete();
    }

    // Only remove if we're still the current completer (handles overwrites)
    if (_inFlightQueries[queryKey] == completer) {
      _inFlightQueries.remove(queryKey);
      _logger.fine('Cleaned up query $queryKey');
    }
  }

  /// Returns true if a query is currently in-flight.
  ///
  /// This is primarily for testing and debugging.
  @visibleForTesting
  bool isQueryInFlight(String queryKey) {
    return _inFlightQueries.containsKey(queryKey);
  }

  /// Returns the number of in-flight queries.
  ///
  /// This is primarily for testing and debugging.
  @visibleForTesting
  int get inFlightCount => _inFlightQueries.length;
}
