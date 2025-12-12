import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/src/query_synchronizer.dart';

void main() {
  group('QuerySynchronizer', () {
    late QuerySynchronizer sync;

    setUp(() {
      sync = QuerySynchronizer();
    });

    test('should register and complete a query', () async {
      const queryKey = 'entity123/myQuery';

      // Register query
      final completer = sync.registerQuery(queryKey);
      expect(sync.isQueryInFlight(queryKey), isTrue);
      expect(sync.inFlightCount, 1);

      // Complete query
      sync.completeQuery(queryKey);

      // Verify completer is completed
      await expectLater(completer.future, completes);
      expect(sync.isQueryInFlight(queryKey), isFalse);
      expect(sync.inFlightCount, 0);
    });

    test('should wait for in-flight query', () async {
      const queryKey = 'entity123/myQuery';
      var waitCompleted = false;

      // Register query
      sync.registerQuery(queryKey);

      // Start waiting (this should block until query completes)
      final waitFuture = sync.waitForQuery(queryKey).then((_) {
        waitCompleted = true;
      });

      // Verify wait hasn't completed yet
      await Future.delayed(Duration(milliseconds: 10));
      expect(waitCompleted, isFalse);

      // Complete the query
      sync.completeQuery(queryKey);

      // Wait should now complete
      await waitFuture;
      expect(waitCompleted, isTrue);
    });

    test('should not wait for non-existent query', () async {
      const queryKey = 'entity123/myQuery';

      // Wait for query that was never registered
      // This should complete immediately
      await expectLater(sync.waitForQuery(queryKey), completes);
    });

    test('should handle cleanup after error', () async {
      const queryKey = 'entity123/myQuery';

      // Register query
      final completer = sync.registerQuery(queryKey);
      expect(sync.isQueryInFlight(queryKey), isTrue);

      // Cleanup (simulating error handling)
      sync.cleanupQuery(queryKey, completer);

      // Verify cleanup completed the query
      await expectLater(completer.future, completes);
      expect(sync.isQueryInFlight(queryKey), isFalse);
      expect(sync.inFlightCount, 0);
    });

    test('should handle multiple concurrent queries', () async {
      const queryKey1 = 'entity1/query1';
      const queryKey2 = 'entity2/query2';
      const queryKey3 = 'entity3/query3';

      // Register multiple queries
      final completer1 = sync.registerQuery(queryKey1);
      final completer2 = sync.registerQuery(queryKey2);
      final completer3 = sync.registerQuery(queryKey3);

      expect(sync.inFlightCount, 3);
      expect(sync.isQueryInFlight(queryKey1), isTrue);
      expect(sync.isQueryInFlight(queryKey2), isTrue);
      expect(sync.isQueryInFlight(queryKey3), isTrue);

      // Complete them in different order
      sync.completeQuery(queryKey2);
      expect(sync.inFlightCount, 2);
      await expectLater(completer2.future, completes);

      sync.completeQuery(queryKey1);
      expect(sync.inFlightCount, 1);
      await expectLater(completer1.future, completes);

      sync.completeQuery(queryKey3);
      expect(sync.inFlightCount, 0);
      await expectLater(completer3.future, completes);
    });

    test('should not fail when completing already completed query', () {
      const queryKey = 'entity123/myQuery';

      // Register and complete
      sync.registerQuery(queryKey);
      sync.completeQuery(queryKey);

      // Try to complete again - should not throw
      expect(() => sync.completeQuery(queryKey), returnsNormally);
      expect(sync.inFlightCount, 0);
    });

    test('should handle cleanup of non-current completer', () async {
      const queryKey = 'entity123/myQuery';

      // Register first query
      final completer1 = sync.registerQuery(queryKey);

      // Register same query again (overwrites)
      final completer2 = sync.registerQuery(queryKey);

      // Cleanup first completer (should not remove query since completer2 is current)
      sync.cleanupQuery(queryKey, completer1);

      // Query should still be in-flight
      expect(sync.isQueryInFlight(queryKey), isTrue);
      expect(sync.inFlightCount, 1);

      // First completer should be completed though
      await expectLater(completer1.future, completes);

      // Complete the actual current query
      sync.completeQuery(queryKey);
      await expectLater(completer2.future, completes);
      expect(sync.inFlightCount, 0);
    });

    test('should allow wait and complete to race safely', () async {
      const queryKey = 'entity123/myQuery';
      final results = <String>[];

      // Register query
      sync.registerQuery(queryKey);

      // Start multiple waiters
      final wait1 = sync
          .waitForQuery(queryKey)
          .then((_) => results.add('wait1'));
      final wait2 = sync
          .waitForQuery(queryKey)
          .then((_) => results.add('wait2'));
      final wait3 = sync
          .waitForQuery(queryKey)
          .then((_) => results.add('wait3'));

      // Complete query once
      sync.completeQuery(queryKey);

      // All waiters should complete
      await Future.wait([wait1, wait2, wait3]);

      expect(results, hasLength(3));
      expect(results, containsAll(['wait1', 'wait2', 'wait3']));
    });
  });
}
