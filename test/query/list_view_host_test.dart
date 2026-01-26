import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/query.dart';

import '../helpers/mock_connection.dart';

// Test query with a list view
class TestQuery extends EntityQuery {
  @override
  String get entityName => 'TestEntity';

  final list = EntityListView(
    'testList',
    query: TestListItemQuery(),
    attrs: ['attr1'],
  );

  @override
  void initViews(EntityQueryGroup views) {
    views.add(list);
  }
}

class TestListItemQuery extends EntityQuery {
  @override
  String get entityName => 'TestListItem';

  final value = EntityValueView<String>('itemValue');

  @override
  void initViews(EntityQueryGroup views) {
    views.add(value);
  }
}

// Query with subscribed list view for testing subscriptions
class TestQueryWithSubscribedList extends EntityQuery {
  @override
  String get entityName => 'TestEntity';

  final list = EntityListView(
    'subscribedList',
    query: TestListItemQuery(),
    subscribe: true,
  );

  @override
  void initViews(EntityQueryGroup views) {
    views.add(list);
  }
}

void main() {
  group('ActorListViewHost', () {
    late MockConnection mockConn;
    late TestHordaClientSystem system;
    late ActorQueryHost queryHost;
    late ActorListViewHost listHost;
    late String pageId;

    setUp(() {
      mockConn = MockConnection();
      system = TestHordaClientSystem.withConnection(conn: mockConn);

      final query = TestQuery();
      queryHost = query.rootHost('Test', system);

      // Attach the list view to get the host
      final result = QueryResultBuilder()
        ..list('testList', {}, '1:0:0:0', 'test-page-id', (rb) {});

      queryHost.attach('actor-1', result.build());

      // Get the list view host
      listHost = queryHost.children['testList'] as ActorListViewHost;
      pageId = listHost.pageId;

      // Initialize with empty list
      listHost.value;
    });

    test('should add item with ListPageItemAdded', () async {
      final change = ListPageItemAdded(
        pageId: pageId,
        pos: 1.0,
        refId: 'item-value-1',
      );

      final previousValue = <ListItem>[];
      final result = await listHost.project(
        'actor-1',
        'testList',
        change,
        previousValue,
      );

      expect(result, isA<List<ListItem>>());
      expect(result.length, 1);
      expect(result[0].position, 1.0);
      expect(result[0].refId, 'item-value-1');
    });

    test('should remove item with ListPageItemRemoved', () async {
      // Setup: Add an item first
      final addChange = ListPageItemAdded(
        pageId: pageId,
        pos: 1.0,
        refId: 'item-value-1',
      );

      var previousValue = <ListItem>[];
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        addChange,
        previousValue,
      );

      expect(previousValue.length, 1);

      // Now remove it
      final removeChange = ListPageItemRemoved(
        pageId: pageId,
        pos: 1.0,
      );

      final result = await listHost.project(
        'actor-1',
        'testList',
        removeChange,
        previousValue,
      );

      expect(result, isA<List<ListItem>>());
      expect(result.length, 0);
    });

    test('should clear all items with ListPageCleared', () async {
      // Setup: Add multiple items
      var previousValue = <ListItem>[];

      for (var i = 1; i <= 3; i++) {
        final change = ListPageItemAdded(
          pageId: pageId,
          pos: i.toDouble(),
          refId: 'item-value-$i',
        );
        previousValue = await listHost.project(
          'actor-1',
          'testList',
          change,
          previousValue,
        );
      }

      expect(previousValue.length, 3);

      // Now clear all
      final clearChange = ListPageCleared(pageId: pageId);

      final result = await listHost.project(
        'actor-1',
        'testList',
        clearChange,
        previousValue,
      );

      expect(result, isA<List<ListItem>>());
      expect(result.length, 0);
    });

    test('should ignore changes with different pageId', () async {
      final differentPageId = 'different-page-id';

      // Add an item with correct pageId
      final addChange = ListPageItemAdded(
        pageId: pageId,
        pos: 1.0,
        refId: 'item-value-1',
      );

      var previousValue = <ListItem>[];
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        addChange,
        previousValue,
      );

      expect(previousValue.length, 1);

      // Try to add another item with wrong pageId
      final wrongPageIdChange = ListPageItemAdded(
        pageId: differentPageId,
        pos: 2.0,
        refId: 'item-value-2',
      );

      final result = await listHost.project(
        'actor-1',
        'testList',
        wrongPageIdChange,
        previousValue,
      );

      // Should return unchanged list
      expect(result, isA<List<ListItem>>());
      expect(result.length, 1);
      expect(result[0].position, 1.0);
    });

    test('should handle non-ListPageChange with warning', () async {
      // Use a different change type (not a ListPageChange)
      final wrongChange = ValueViewChanged<String>('some-value');

      final previousValue = <ListItem>[];
      final result = await listHost.project(
        'actor-1',
        'testList',
        wrongChange,
        previousValue,
      );

      // Should return unchanged list
      expect(result, previousValue);
      expect(result.length, 0);
    });

    test('should add multiple items in sequence', () async {
      var previousValue = <ListItem>[];

      // Add first item
      final change1 = ListPageItemAdded(
        pageId: pageId,
        pos: 1.0,
        refId: 'item-value-1',
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change1,
        previousValue,
      );

      // Add second item
      final change2 = ListPageItemAdded(
        pageId: pageId,
        pos: 2.0,
        refId: 'item-value-2',
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change2,
        previousValue,
      );

      // Add third item
      final change3 = ListPageItemAdded(
        pageId: pageId,
        pos: 3.0,
        refId: 'item-value-3',
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change3,
        previousValue,
      );

      expect(result.length, 3);
      expect(result[0].position, 1.0);
      expect(result[1].position, 2.0);
      expect(result[2].position, 3.0);
    });

    test('should remove item from middle of list', () async {
      // Setup: Add three items
      var previousValue = <ListItem>[];

      for (var i = 1; i <= 3; i++) {
        final change = ListPageItemAdded(
          pageId: pageId,
          pos: i.toDouble(),
          refId: 'item-value-$i',
        );
        previousValue = await listHost.project(
          'actor-1',
          'testList',
          change,
          previousValue,
        );
      }

      expect(previousValue.length, 3);

      // Remove the middle item (pos 2.0)
      final removeChange = ListPageItemRemoved(
        pageId: pageId,
        pos: 2.0,
      );

      final result = await listHost.project(
        'actor-1',
        'testList',
        removeChange,
        previousValue,
      );

      expect(result.length, 2);
      expect(result[0].position, 1.0);
      expect(result[1].position, 3.0);
    });

    test('should include pageId in subscriptions()', () {
      // Create a new query with subscribe flag set
      final subscribedQuery = TestQueryWithSubscribedList();
      final subscribedHost = subscribedQuery.rootHost('Test', system);

      // Attach the list view
      final result = QueryResultBuilder()
        ..list('subscribedList', {}, '1:0:0:0', 'test-page-id', (rb) {});

      subscribedHost.attach('actor-2', result.build());

      // Get the list view host
      final subscribedListHost =
          subscribedHost.children['subscribedList'] as ActorListViewHost;

      // Get subscriptions
      final subs = subscribedListHost.subscriptions();

      // Verify subscription includes pageId
      expect(subs, isNotEmpty);
      expect(subs.length, 1);

      final sub = subs.first;
      expect(sub.entityName, 'TestEntity');
      expect(sub.id, 'actor-2');
      expect(sub.name, 'subscribedList');
      expect(sub.pageId, isNotNull);
      expect(sub.pageId, subscribedListHost.pageId);
    });

    test(
      'should add item to end when position is greater than first',
      () async {
        var previousValue = <ListItem>[];

        // Add first item with position 1.0
        final change1 = ListPageItemAdded(
          pageId: pageId,
          pos: 1.0,
          refId: 'item-value-a',
        );
        previousValue = await listHost.project(
          'actor-1',
          'testList',
          change1,
          previousValue,
        );

        // Add second item with position 2.0 (greater than 1.0)
        final change2 = ListPageItemAdded(
          pageId: pageId,
          pos: 2.0,
          refId: 'item-value-b',
        );
        final result = await listHost.project(
          'actor-1',
          'testList',
          change2,
          previousValue,
        );

        expect(result.length, 2);
        expect(result[0].position, 1.0);
        expect(result[1].position, 2.0);
      },
    );

    test(
      'should add item to beginning when position is less than first',
      () async {
        var previousValue = <ListItem>[];

        // Add first item with position 2.0
        final change1 = ListPageItemAdded(
          pageId: pageId,
          pos: 2.0,
          refId: 'item-value-b',
        );
        previousValue = await listHost.project(
          'actor-1',
          'testList',
          change1,
          previousValue,
        );

        // Add second item with position 1.0 (less than 2.0)
        final change2 = ListPageItemAdded(
          pageId: pageId,
          pos: 1.0,
          refId: 'item-value-a',
        );
        final result = await listHost.project(
          'actor-1',
          'testList',
          change2,
          previousValue,
        );

        expect(result.length, 2);
        expect(result[0].position, 1.0); // Should be at beginning
        expect(result[1].position, 2.0);
      },
    );

    test('should maintain correct order based on position comparison', () async {
      var previousValue = <ListItem>[];

      // Add item with position 3.0
      final change1 = ListPageItemAdded(
        pageId: pageId,
        pos: 3.0,
        refId: 'item-value-c',
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change1,
        previousValue,
      );

      // Add item with position 1.0 (less than 3.0, should go to beginning)
      final change2 = ListPageItemAdded(
        pageId: pageId,
        pos: 1.0,
        refId: 'item-value-a',
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change2,
        previousValue,
      );

      // Add item with position 4.0 (greater than 1.0, should go to end)
      final change3 = ListPageItemAdded(
        pageId: pageId,
        pos: 4.0,
        refId: 'item-value-d',
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change3,
        previousValue,
      );

      // Add item with position 0.5 (less than 1.0, should go to beginning)
      final change4 = ListPageItemAdded(
        pageId: pageId,
        pos: 0.5,
        refId: 'item-value-1',
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change4,
        previousValue,
      );

      expect(result.length, 4);
      // Expected order: [0.5, 1.0, 3.0, 4.0]
      // Logic: new position < first position → insert at beginning, else add to end
      expect(result[0].position, 0.5);
      expect(result[1].position, 1.0);
      expect(result[2].position, 3.0);
      expect(result[3].position, 4.0);
    });
  });
}
