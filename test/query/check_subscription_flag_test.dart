import 'package:horda_client/horda_client.dart';
import 'package:flutter_test/flutter_test.dart';

class TestQuery extends EntityQuery {
  final userName = EntityValueView<String>('name', subscribe: true);

  final threadCount = EntityCounterView('threadCount', subscribe: false);

  final speechCount = EntityCounterView('speechCount', subscribe: true);

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(userName)
      ..add(threadCount)
      ..add(speechCount);
  }
}

class RefQuery extends EntityQuery {
  final refview = EntityRefView(
    'name',
    query: TestQuery(),
    attrs: ['attr1', 'attr2'],
    subscribe: false,
  );

  @override
  void initViews(EntityQueryGroup views) {
    views..add(refview);
  }
}

void main() {
  test('query should handle subscribe flag', () async {
    final system = HordaClientSystem(
      url: 'ws://0.0.0.0:8080/ws',
      apiKey: 'apikey',
      authProvider: TestAuthProvider(),
    );

    final testQuery = TestQuery().rootHost('Test', system);

    testQuery.actorId = 'actor1';

    testQuery.children.values.forEach((element) {
      element.actorId = 'actor1';
    });

    final subs = testQuery.subscriptions();
    final subNames = ['name', 'speechCount'];

    expect(subs.map((e) => e.name).toList(), subNames);
    expect(subs.length, 2);
  });

  test('refquery should handle subscribe flag within subqueries', () async {
    final system = HordaClientSystem(
      url: 'ws://0.0.0.0:8080/ws',
      apiKey: 'apikey',
      authProvider: TestAuthProvider(),
    );

    final refQuery = RefQuery().rootHost('Test', system);

    var rb = QueryResultBuilder()
      ..ref(
        'name',
        'actor2',
        {
          'attr1': {'val': 'a1', 'chid': '1:0:0:0'},
          'attr2': {'val': 20, 'chid': '1:0:0:0'},
        },
        '101:0:0:0',
        (rb) {
          rb
            ..val('name', 'user1', '1:0:0:0')
            ..val('threadCount', 10, '2:0:0:0')
            ..val('speechCount', 100, '3:0:0:0');
        },
      );

    var res = rb.build();

    refQuery.attach('actor1', res);

    final subs = refQuery.subscriptions();
    final subNames = ['name', 'speechCount'];

    expect(subNames, subs.map((e) => e.name).toList());
    expect(subs.length, 2);
  });
}
