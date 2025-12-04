import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/connection.dart';
import 'package:logging/logging.dart';

// Test queries for widget testing
class SimpleQuery extends EntityQuery {
  @override
  String get entityName => 'SimpleEntity';

  final view1 = EntityValueView<String>('view1');
  final view2 = EntityValueView<int>('view2');

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(view1)
      ..add(view2);
  }
}

class QueryWithRef extends EntityQuery {
  @override
  String get entityName => 'ParentEntity';

  final parentName = EntityValueView<String>('name');
  final refView = EntityRefView(
    'refView',
    query: SimpleQuery(),
  );

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(parentName)
      ..add(refView);
  }
}

class QueryWithList extends EntityQuery {
  @override
  String get entityName => 'ListEntity';

  final listView = EntityListView('listView', query: SimpleQuery());

  @override
  void initViews(EntityQueryGroup views) {
    views.add(listView);
  }
}

/// Mock connection that tracks subscription calls for testing
class MockConnection extends ValueNotifier<HordaConnectionState>
    implements Connection {
  MockConnection()
    : logger = Logger('MockConnection'),
      super(ConnectionStateConnected());

  final Logger logger;

  @override
  String get url => 'ws://test';

  @override
  String get apiKey => 'test-api-key';

  final unsubscribeCallLog = <List<ActorViewSub>>[];

  @override
  Future<void> open() async {}

  @override
  void close() {}

  @override
  Future<void> reopen() async {}

  @override
  Future<QueryResult> query({
    required String actorId,
    required QueryDef def,
  }) async {
    return _createMockResult(actorId, def);
  }

  @override
  Future<QueryResult> queryAndSubscribe({
    required String actorId,
    required QueryDef def,
  }) async {
    logger.info('queryAndSubscribe called for $actorId');
    return _createMockResult(actorId, def);
  }

  @override
  Future<void> subscribeViews(Iterable<ActorViewSub> subs) async {
    // Deprecated - no-op
    logger.info('subscribeViews called (deprecated)');
  }

  @override
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs) async {
    logger.info('unsubscribeViews called with ${subs.length} subs');
    unsubscribeCallLog.add(subs.toList());
  }

  @override
  Future<void> sendEntity(
    String actorName,
    String to,
    RemoteCommand cmd,
  ) async {}

  @override
  Future<E> callEntity<E extends RemoteEvent>(
    String actorName,
    String to,
    RemoteCommand cmd,
    FromJsonFun<E> fac,
    Duration timeout,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ProcessResult> runProcess(RemoteEvent event, Duration timeout) async {
    throw UnimplementedError();
  }

  QueryResult _createMockResult(String actorId, QueryDef def) {
    final builder = QueryResultBuilder();
    _buildViewsFromDef(actorId, def, builder);
    return builder.build();
  }

  /// Recursively builds query result views based on the query definition
  void _buildViewsFromDef(
    String actorId,
    QueryDef def,
    QueryResultBuilder builder,
  ) {
    for (var entry in def.views.entries) {
      final viewName = entry.key;
      final viewDef = entry.value;

      if (viewDef is ValueQueryDef) {
        // Create mock value based on view name
        final mockValue = _getMockValue(viewName);
        builder.val(viewName, mockValue, '1:0:0:0');
      } else if (viewDef is RefQueryDef) {
        // Create mock ref view with nested query
        final refId = '$actorId-$viewName-ref';
        builder.ref(viewName, refId, {}, '1:0:0:0', (refBuilder) {
          _buildViewsFromDef(refId, viewDef.query, refBuilder);
        });
      } else if (viewDef is ListQueryDef) {
        // Create mock list view with nested query items
        builder.list(viewName, {}, '1:0:0:0', (listBuilder) {
          // Create 2 mock items with XID keys
          for (var i = 0; i < 2; i++) {
            final xidKey = 'xid-$actorId-$viewName-$i';
            final itemId = '$actorId-$viewName-item$i';
            listBuilder.item(xidKey, itemId, (itemBuilder) {
              _buildViewsFromDef(itemId, viewDef.query, itemBuilder);
            });
          }
        });
      }
    }
  }

  /// Returns a mock value based on the view name
  dynamic _getMockValue(String viewName) {
    // Return appropriate mock values based on common view names
    if (viewName.contains('name')) return 'test-name';
    if (viewName == 'view1') return 'test-value';
    if (viewName == 'view2') return 42;

    // Default: return string based on view name
    return 'mock-$viewName';
  }
}

void main() {
  group('View Subscription Tracking - Widget Tests', () {
    late MockConnection mockConn;
    late TestHordaClientSystem system;

    setUp(() {
      mockConn = MockConnection();
      system = TestHordaClientSystem.withConnection(
        conn: mockConn,
      );
    });

    Widget buildTestWidget({
      required List<Widget> queryProviders,
    }) {
      return MaterialApp(
        home: HordaSystemProvider(
          system: system,
          child: Column(
            children: queryProviders,
          ),
        ),
      );
    }

    testWidgets(
      'should track subscriptions on mount and untrack on dispose',
      (tester) async {
        // Build widget with single query provider
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              EntityQueryProvider(
                entityId: 'actor1',
                query: SimpleQuery(),
                system: system,
                child: const SizedBox(),
              ),
            ],
          ),
        );

        // Wait for async operations
        await tester.pumpAndSettle();

        // Verify subscriptions were tracked via atomic queryAndSubscribe
        final counts = system.viewSubCount;
        expect(counts['SimpleEntity/actor1/view1'], 1);
        expect(counts['SimpleEntity/actor1/view2'], 1);

        // Dispose widget by removing it
        await tester.pumpWidget(
          buildTestWidget(queryProviders: []),
        );
        await tester.pumpAndSettle();

        // Verify unsubscribe was called with exactly 2 views (view1, view2)
        expect(mockConn.unsubscribeCallLog.length, 1);
        expect(mockConn.unsubscribeCallLog[0].length, 2);

        // Verify ref counts were decremented
        expect(system.viewSubCount, isEmpty);
      },
    );

    testWidgets(
      'should reference count shared subscriptions across multiple widgets',
      (tester) async {
        // Mount first widget
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              Container(
                key: const ValueKey('container1'),
                child: EntityQueryProvider(
                  entityId: 'actor1',
                  query: SimpleQuery(),
                  system: system,
                  child: const SizedBox(),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Verify ref count = 1
        expect(system.viewSubCount['SimpleEntity/actor1/view1'], 1);
        expect(system.viewSubCount['SimpleEntity/actor1/view2'], 1);

        // Mount second widget with SAME entityId and query
        // This should increment ref count on the same view subscriptions
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              Container(
                key: const ValueKey('container1'),
                child: EntityQueryProvider(
                  entityId: 'actor1',
                  query: SimpleQuery(),
                  system: system,
                  child: const SizedBox(),
                ),
              ),
              Container(
                key: const ValueKey('container2'),
                child: EntityQueryProvider(
                  entityId: 'actor1',
                  query: SimpleQuery(),
                  system: system,
                  child: const SizedBox(),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Verify ref count increased to 2 for the same views
        expect(system.viewSubCount['SimpleEntity/actor1/view1'], 2);
        expect(system.viewSubCount['SimpleEntity/actor1/view2'], 2);

        // Remove first widget
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              Container(
                key: const ValueKey('container2'),
                child: EntityQueryProvider(
                  entityId: 'actor1',
                  query: SimpleQuery(),
                  system: system,
                  child: const SizedBox(),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Verify ref count decremented to 1 (still subscribed via widget2)
        expect(system.viewSubCount['SimpleEntity/actor1/view1'], 1);
        expect(system.viewSubCount['SimpleEntity/actor1/view2'], 1);

        // Verify unsubscribe was NOT called (ref count still > 0)
        expect(
          mockConn.unsubscribeCallLog.length,
          0,
          reason: 'Should not unsubscribe while ref count > 0',
        );

        // Remove second widget
        await tester.pumpWidget(
          buildTestWidget(queryProviders: []),
        );
        await tester.pumpAndSettle();

        // Verify all subscriptions cleaned up (ref count reached 0)
        expect(
          system.viewSubCount['SimpleEntity/actor1/view1'],
          isNull,
        );
        expect(
          system.viewSubCount['SimpleEntity/actor1/view2'],
          isNull,
        );

        // Now unsubscribe should have been called with exactly 2 views (ref count reached 0)
        expect(
          mockConn.unsubscribeCallLog.length,
          1,
          reason: 'Should unsubscribe when ref count reaches 0',
        );
        expect(mockConn.unsubscribeCallLog[0].length, 2);
        expect(system.viewSubCount, isEmpty);
      },
    );

    testWidgets(
      'should track nested ref view subscriptions',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              EntityQueryProvider(
                entityId: 'parent1',
                query: QueryWithRef(),
                system: system,
                child: const SizedBox(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final counts = system.viewSubCount;

        // Verify root subscriptions tracked
        expect(counts['ParentEntity/parent1/name'], 1);
        expect(counts['ParentEntity/parent1/refView'], 1);

        // Verify nested ref subscriptions tracked
        expect(counts['SimpleEntity/parent1-refView-ref/view1'], 1);
        expect(counts['SimpleEntity/parent1-refView-ref/view2'], 1);

        // Dispose and verify all unsubscribed
        await tester.pumpWidget(buildTestWidget(queryProviders: []));
        await tester.pumpAndSettle();

        // Verify unsubscribe was called with exactly 4 views (name, refView, view1, view2)
        expect(mockConn.unsubscribeCallLog.length, 1);
        expect(mockConn.unsubscribeCallLog[0].length, 4);
        expect(system.viewSubCount, isEmpty);
      },
    );

    testWidgets(
      'should track nested list view subscriptions',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              EntityQueryProvider(
                entityId: 'list1',
                query: QueryWithList(),
                system: system,
                child: const SizedBox(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final counts = system.viewSubCount;

        // Verify list view subscription tracked
        expect(counts['ListEntity/list1/listView'], 1);

        // Verify item subscriptions tracked (2 items created by mock)
        expect(counts['SimpleEntity/list1-listView-item0/view1'], 1);
        expect(counts['SimpleEntity/list1-listView-item0/view2'], 1);
        expect(counts['SimpleEntity/list1-listView-item1/view1'], 1);
        expect(counts['SimpleEntity/list1-listView-item1/view2'], 1);

        // Dispose and verify all unsubscribed
        await tester.pumpWidget(buildTestWidget(queryProviders: []));
        await tester.pumpAndSettle();

        // Verify unsubscribe was called with exactly 5 views (listView + 2 items × 2 views each)
        expect(mockConn.unsubscribeCallLog.length, 1);
        expect(mockConn.unsubscribeCallLog[0].length, 5);
        expect(system.viewSubCount, isEmpty);
      },
    );

    testWidgets(
      'should handle different queries for different entites',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            queryProviders: [
              EntityQueryProvider(
                entityId: 'entity1',
                query: SimpleQuery(),
                system: system,
                child: const SizedBox(),
              ),
              EntityQueryProvider(
                entityId: 'entity2',
                query: QueryWithRef(),
                system: system,
                child: const SizedBox(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final counts = system.viewSubCount;

        // SimpleQuery uses SimpleEntity
        expect(counts['SimpleEntity/entity1/view1'], 1);
        expect(counts['SimpleEntity/entity1/view2'], 1);

        // QueryWithRef uses ParentEntity
        expect(counts['ParentEntity/entity2/name'], 1);
        expect(counts['ParentEntity/entity2/refView'], 1);

        // Verify nested ref subscriptions
        expect(counts['SimpleEntity/entity2-refView-ref/view1'], 1);
        expect(counts['SimpleEntity/entity2-refView-ref/view2'], 1);

        // Total: 6 views tracked
        expect(counts.length, 6);

        // Dispose and verify all unsubscribed
        await tester.pumpWidget(buildTestWidget(queryProviders: []));
        await tester.pumpAndSettle();

        // Verify unsubscribe was called 2 times:
        expect(mockConn.unsubscribeCallLog.length, 2);

        // Verify one call unsubscribed 2 views (SimpleQuery)
        expect(
          mockConn.unsubscribeCallLog,
          // Call order is not deterministic, so use contains matcher.
          contains(hasLength(2)),
          reason: 'Should unsubscribe 2 views from SimpleQuery',
        );

        // Verify one call unsubscribed 4 views (QueryWithRef with nested)
        expect(
          mockConn.unsubscribeCallLog,
          // Call order is not deterministic, so use contains matcher.
          contains(hasLength(4)),
          reason:
              'Should unsubscribe 4 views from QueryWithRef including nested',
        );

        // No views are tracked any more.
        expect(system.viewSubCount, isEmpty);
      },
    );
  });
}
