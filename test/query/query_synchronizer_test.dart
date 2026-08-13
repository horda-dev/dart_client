import 'package:flutter_test/flutter_test.dart';
import 'package:horda_core/horda_core.dart';
import 'package:horda_client/src/query_synchronizer.dart';

void main() {
  group('QuerySynchronizer', () {
    late QuerySynchronizer sync;

    setUp(() {
      sync = QuerySynchronizer();
    });

    test('should register and release a query', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register query
      final query = sync.register('id1', queryDef);
      expect(query.isDone, isFalse);
      expect(sync.inFlightCount, 1);

      // Release query
      sync.release(query);

      await expectLater(query.done, completes);
      expect(query.isDone, isTrue);
      expect(sync.inFlightCount, 0);
    });

    test('should wait for in-flight query', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});
      var waitCompleted = false;

      // Register query
      final query = sync.register('id1', queryDef);

      // Start waiting (this should block until query completes)
      final waitFuture = sync.waitForQuery(queryDef).then((_) {
        waitCompleted = true;
      });

      // Verify wait hasn't completed yet
      await Future.delayed(Duration(milliseconds: 10));
      expect(waitCompleted, isFalse);

      // Release the query
      sync.release(query);

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

    test('should handle release after error', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      // Register query
      final query = sync.register('id1', queryDef);
      expect(sync.inFlightCount, 1);

      // Release (simulating error handling)
      sync.release(query);

      await expectLater(query.done, completes);
      expect(sync.inFlightCount, 0);
    });

    test('should handle multiple concurrent queries', () async {
      final queryDef1 = QueryDef('entity1', {'view1': ValueQueryDef()});
      final queryDef2 = QueryDef('entity2', {'view1': ValueQueryDef()});
      final queryDef3 = QueryDef('entity3', {'view1': ValueQueryDef()});

      // Register multiple queries
      final query1 = sync.register('id1', queryDef1);
      final query2 = sync.register('id2', queryDef2);
      final query3 = sync.register('id3', queryDef3);

      expect(sync.inFlightCount, 3);

      // Release them in a different order than they were registered
      sync.release(query2);
      expect(sync.inFlightCount, 2);
      expect(query1.isDone, isFalse);
      expect(query3.isDone, isFalse);
      await expectLater(query2.done, completes);

      sync.release(query1);
      expect(sync.inFlightCount, 1);
      await expectLater(query1.done, completes);

      sync.release(query3);
      expect(sync.inFlightCount, 0);
      await expectLater(query3.done, completes);
    });

    test('should not fail when releasing an already released query', () {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      final query = sync.register('id1', queryDef);
      sync.release(query);

      // Callers release from a finally block, so a second release must be safe
      expect(() => sync.release(query), returnsNormally);
      expect(sync.inFlightCount, 0);
    });

    test('should track identical concurrent queries independently', () {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      final first = sync.register('id1', queryDef);
      final second = sync.register('id2', queryDef);

      // Neither registration may displace the other
      expect(sync.inFlightCount, 2);

      sync.release(first);

      expect(first.isDone, isTrue);
      expect(second.isDone, isFalse);
      expect(sync.inFlightCount, 1);
    });

    test(
      'should keep waiting when an identical later query is released first',
      () async {
        final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});
        var waitCompleted = false;

        final first = sync.register('id1', queryDef);

        final waitFuture = sync.waitForQuery(queryDef).then((_) {
          waitCompleted = true;
        });

        // A second identical query starts while the unsubscribe is deferred.
        final second = sync.register('id2', queryDef);

        // Releasing the later query must not release the waiter, which is
        // deferred on the first query only.
        sync.release(second);

        await Future.delayed(Duration(milliseconds: 10));
        expect(waitCompleted, isFalse);
        expect(first.isDone, isFalse);

        sync.release(first);

        await waitFuture;
        expect(waitCompleted, isTrue);
      },
    );

    test('should allow wait and release to race safely', () async {
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});
      final results = <String>[];

      // Register query
      final query = sync.register('id1', queryDef);

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

      // Release query once
      sync.release(query);

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

        final query = sync.register('id1', registeredQuery);

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

        // Release the registered query
        sync.release(query);

        // Wait should now complete because the nested query finished
        await waitFuture;
        expect(waitCompleted, isTrue);
      },
    );

    test('should not wait for non-intersecting queries', () async {
      // Register a query for entity1
      final registeredQuery = QueryDef('entity1', {'view1': ValueQueryDef()});
      final query = sync.register('id1', registeredQuery);

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
      sync.release(query);
    });

    test('should match intersecting queries across different entity ids', () {
      // Entity ids are not part of intersection matching: a single unsubscribe
      // can cover child hosts belonging to many entities.
      final queryDef = QueryDef('entity1', {'view1': ValueQueryDef()});

      sync.register('id1', queryDef);

      var waitCompleted = false;
      sync.waitForQuery(queryDef).then((_) => waitCompleted = true);

      expect(waitCompleted, isFalse);
      expect(sync.inFlightCount, 1);
    });
  });
}
