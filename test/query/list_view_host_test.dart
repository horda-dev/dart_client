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
        ..list('testList', {}, '1:0:0:0', (rb) {});

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
        key: 'item-key-1',
        value: 'item-value-1',
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
      expect(result[0].key, 'item-key-1');
      expect(result[0].value, 'item-value-1');
    });

    test('should remove item with ListPageItemRemoved', () async {
      // Setup: Add an item first
      final addChange = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-1',
        value: 'item-value-1',
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
        key: 'item-key-1',
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
          key: 'item-key-$i',
          value: 'item-value-$i',
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
        key: 'item-key-1',
        value: 'item-value-1',
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
        key: 'item-key-2',
        value: 'item-value-2',
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
      expect(result[0].key, 'item-key-1');
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
        key: 'item-key-1',
        value: 'item-value-1',
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
        key: 'item-key-2',
        value: 'item-value-2',
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
        key: 'item-key-3',
        value: 'item-value-3',
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change3,
        previousValue,
      );

      expect(result.length, 3);
      expect(result[0].key, 'item-key-1');
      expect(result[1].key, 'item-key-2');
      expect(result[2].key, 'item-key-3');
    });

    test('should remove item from middle of list', () async {
      // Setup: Add three items
      var previousValue = <ListItem>[];

      for (var i = 1; i <= 3; i++) {
        final change = ListPageItemAdded(
          pageId: pageId,
          key: 'item-key-$i',
          value: 'item-value-$i',
        );
        previousValue = await listHost.project(
          'actor-1',
          'testList',
          change,
          previousValue,
        );
      }

      expect(previousValue.length, 3);

      // Remove the middle item (key-2)
      final removeChange = ListPageItemRemoved(
        pageId: pageId,
        key: 'item-key-2',
      );

      final result = await listHost.project(
        'actor-1',
        'testList',
        removeChange,
        previousValue,
      );

      expect(result.length, 2);
      expect(result[0].key, 'item-key-1');
      expect(result[1].key, 'item-key-3');
    });

    test('should include pageId in subscriptions()', () {
      // Create a new query with subscribe flag set
      final subscribedQuery = TestQueryWithSubscribedList();
      final subscribedHost = subscribedQuery.rootHost('Test', system);

      // Attach the list view
      final result = QueryResultBuilder()
        ..list('subscribedList', {}, '1:0:0:0', (rb) {});

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

    test('should add item to end when toBeginning is false', () async {
      var previousValue = <ListItem>[];

      // Add first item with toBeginning: false
      final change1 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-1',
        value: 'item-value-1',
        toBeginning: false,
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change1,
        previousValue,
      );

      // Add second item with toBeginning: false
      final change2 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-2',
        value: 'item-value-2',
        toBeginning: false,
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change2,
        previousValue,
      );

      expect(result.length, 2);
      expect(result[0].key, 'item-key-1');
      expect(result[1].key, 'item-key-2');
    });

    test('should add item to beginning when toBeginning is true', () async {
      var previousValue = <ListItem>[];

      // Add first item with toBeginning: false
      final change1 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-1',
        value: 'item-value-1',
        toBeginning: false,
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change1,
        previousValue,
      );

      // Add second item with toBeginning: true
      final change2 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-2',
        value: 'item-value-2',
        toBeginning: true,
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change2,
        previousValue,
      );

      expect(result.length, 2);
      expect(result[0].key, 'item-key-2'); // Should be at beginning
      expect(result[1].key, 'item-key-1');
    });

    test('should maintain order when mixing toBeginning true/false', () async {
      var previousValue = <ListItem>[];

      // Add item 1 to end (toBeginning: false)
      final change1 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-1',
        value: 'item-value-1',
        toBeginning: false,
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change1,
        previousValue,
      );

      // Add item 2 to beginning (toBeginning: true)
      final change2 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-2',
        value: 'item-value-2',
        toBeginning: true,
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change2,
        previousValue,
      );

      // Add item 3 to end (toBeginning: false)
      final change3 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-3',
        value: 'item-value-3',
        toBeginning: false,
      );
      previousValue = await listHost.project(
        'actor-1',
        'testList',
        change3,
        previousValue,
      );

      // Add item 4 to beginning (toBeginning: true)
      final change4 = ListPageItemAdded(
        pageId: pageId,
        key: 'item-key-4',
        value: 'item-value-4',
        toBeginning: true,
      );
      final result = await listHost.project(
        'actor-1',
        'testList',
        change4,
        previousValue,
      );

      expect(result.length, 4);
      // Expected order: [4, 2, 1, 3]
      // 1 added to end, 2 added to beginning, 3 added to end, 4 added to beginning
      expect(result[0].key, 'item-key-4');
      expect(result[1].key, 'item-key-2');
      expect(result[2].key, 'item-key-1');
      expect(result[3].key, 'item-key-3');
    });
  });
}
