import 'package:flutter_test/flutter_test.dart';
import 'package:horda_core/horda_core.dart';
import 'package:horda_client/src/query_synchronizer.dart';

void main() {
  group('QuerySynchronizer', () {
    late QuerySynchronizer sync;

    setUp(() {
      sync = QuerySynchronizer();
    });

    test('should register and complete a query', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register query
      final completer = sync.registerQuery(queryDef);
      expect(sync.isQueryInFlight(queryDef), isTrue);
      expect(sync.inFlightCount, 1);

      // Complete query
      sync.completeQuery(queryDef);

      // Verify completer is completed
      await expectLater(completer.future, completes);
      expect(sync.isQueryInFlight(queryDef), isFalse);
      expect(sync.inFlightCount, 0);
    });

    test('should wait for in-flight query', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});
      var waitCompleted = false;

      // Register query
      sync.registerQuery(queryDef);

      // Start waiting (this should block until query completes)
      final waitFuture = sync.waitForQuery(queryDef).then((_) {
        waitCompleted = true;
      });

      // Verify wait hasn't completed yet
      await Future.delayed(Duration(milliseconds: 10));
      expect(waitCompleted, isFalse);

      // Complete the query
      sync.completeQuery(queryDef);

      // Wait should now complete
      await waitFuture;
      expect(waitCompleted, isTrue);
    });

    test('should not wait for non-existent query', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Wait for query that was never registered
      // This should complete immediately
      await expectLater(sync.waitForQuery(queryDef), completes);
    });

    test('should handle cleanup after error', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register query
      final completer = sync.registerQuery(queryDef);
      expect(sync.isQueryInFlight(queryDef), isTrue);

      // Cleanup (simulating error handling)
      sync.cleanupQuery(queryDef, completer);

      // Verify cleanup completed the query
      await expectLater(completer.future, completes);
      expect(sync.isQueryInFlight(queryDef), isFalse);
      expect(sync.inFlightCount, 0);
    });

    test('should handle multiple concurrent queries', () async {
      final queryDef1 = QueryDef('entity1', {'view1': ValueQueryDef()});
      final queryDef2 = QueryDef('entity2', {'view1': ValueQueryDef()});
      final queryDef3 = QueryDef('entity3', {'view1': ValueQueryDef()});

      // Register multiple queries
      final completer1 = sync.registerQuery(queryDef1);
      final completer2 = sync.registerQuery(queryDef2);
      final completer3 = sync.registerQuery(queryDef3);

      expect(sync.inFlightCount, 3);
      expect(sync.isQueryInFlight(queryDef1), isTrue);
      expect(sync.isQueryInFlight(queryDef2), isTrue);
      expect(sync.isQueryInFlight(queryDef3), isTrue);

      // Complete them in different order
      sync.completeQuery(queryDef2);
      expect(sync.inFlightCount, 2);
      await expectLater(completer2.future, completes);

      sync.completeQuery(queryDef1);
      expect(sync.inFlightCount, 1);
      await expectLater(completer1.future, completes);

      sync.completeQuery(queryDef3);
      expect(sync.inFlightCount, 0);
      await expectLater(completer3.future, completes);
    });

    test('should not fail when completing already completed query', () {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register and complete
      sync.registerQuery(queryDef);
      sync.completeQuery(queryDef);

      // Try to complete again - should not throw
      expect(() => sync.completeQuery(queryDef), returnsNormally);
      expect(sync.inFlightCount, 0);
    });

    test('should handle cleanup of non-current completer', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register first query
      final completer1 = sync.registerQuery(queryDef);

      // Register same query again (overwrites)
      final completer2 = sync.registerQuery(queryDef);

      // Cleanup first completer (should not remove query since completer2 is current)
      sync.cleanupQuery(queryDef, completer1);

      // Query should still be in-flight
      expect(sync.isQueryInFlight(queryDef), isTrue);
      expect(sync.inFlightCount, 1);

      // First completer should be completed though
      await expectLater(completer1.future, completes);

      // Complete the actual current query
      sync.completeQuery(queryDef);
      await expectLater(completer2.future, completes);
      expect(sync.inFlightCount, 0);
    });

    test('should allow wait and complete to race safely', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});
      final results = <String>[];

      // Register query
      sync.registerQuery(queryDef);

      // Start multiple waiters
      final wait1 = sync
          .waitForQuery(queryDef)
          .then((_) => results.add('wait1'));
      final wait2 = sync
          .waitForQuery(queryDef)
          .then((_) => results.add('wait2'));
      final wait3 = sync
          .waitForQuery(queryDef)
          .then((_) => results.add('wait3'));

      // Complete query once
      sync.completeQuery(queryDef);

      // All waiters should complete
      await Future.wait([wait1, wait2, wait3]);

      expect(results, hasLength(3));
      expect(results, containsAll(['wait1', 'wait2', 'wait3']));
    });

    test(
      'should wait for intersecting nested queries with different structure',
      () async {
        // Register a query with a nested RefQueryDef
        final registeredQuery = QueryDef('entity1', {
          'view1': ValueQueryDef(),
          'refView': RefQueryDef(
            query: QueryDef('entity2', {
              'nestedView': ValueQueryDef(),
              'otherView': ValueQueryDef(),
            }),
            attrs: ['attr1'],
          ),
        });

        sync.registerQuery(registeredQuery);

        // Create a different query that only requests entity2/nestedView
        // This should still intersect because the registered query includes
        // this nested view
        final intersectingQuery = QueryDef('entity2', {
          'nestedView': ValueQueryDef(),
        });

        var waitCompleted = false;

        // Start waiting for the intersecting nested query
        final waitFuture = sync.waitForQuery(intersectingQuery).then((_) {
          waitCompleted = true;
        });

        // Verify wait hasn't completed yet
        await Future.delayed(Duration(milliseconds: 10));
        expect(waitCompleted, isFalse);

        // Complete the registered query
        sync.completeQuery(registeredQuery);

        // Wait should now complete because the nested query finished
        await waitFuture;
        expect(waitCompleted, isTrue);
      },
    );

    test('should not wait for non-intersecting queries', () async {
      // Register a query for entity1
      final registeredQuery = QueryDef('entity1', {'view1': ValueQueryDef()});
      sync.registerQuery(registeredQuery);

      // Create a query for entity2 with no overlap
      final nonIntersectingQuery = QueryDef('entity2', {
        'view1': ValueQueryDef(),
      });

      // Wait for the non-intersecting query should complete immediately
      var waitCompleted = false;
      final waitFuture = sync.waitForQuery(nonIntersectingQuery).then((_) {
        waitCompleted = true;
      });

      // Wait should complete immediately since there's no intersection
      await waitFuture;
      expect(waitCompleted, isTrue);

      // Clean up
      sync.completeQuery(registeredQuery);
    });
  });
}
