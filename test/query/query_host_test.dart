import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/query.dart';

class TestQuery extends EntityQuery {
  @override
  String get entityName => 'TestEntity';

  final view1 = EntityValueView<String>('view1');

  final view2 = EntityValueView<String>('view2');

  final ref = EntityRefView(
    'ref1',
    query: TestRefQuery(),
    attrs: ['attr1', 'attr2'],
  );

  final list = EntityListView(
    'list1',
    query: TestListQuery(),
    attrs: ['attr3', 'attr4'],
  );

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(view1)
      ..add(view2)
      ..add(ref)
      ..add(list);
  }
}

class TestRefQuery extends EntityQuery {
  @override
  String get entityName => 'TestRefEntity';

  final view3 = EntityValueView<String>('view3');

  final view4 = EntityValueView<String>('view4');

  @override
  void initViews(EntityQueryGroup group) {
    group
      ..add(view3)
      ..add(view4);
  }
}

class TestListQuery extends EntityQuery {
  @override
  String get entityName => 'TestListEntity';

  final view5 = EntityValueView<String>('view5');

  final view6 = EntityValueView<String>('view6');

  @override
  void initViews(EntityQueryGroup group) {
    group
      ..add(view5)
      ..add(view6);
  }
}

void main() {
  test('query host should attach its views', () {
    var system = HordaClientSystem(
      url: 'ws://0.0.0.0:8080/ws',
      apiKey: 'apikey',
      authProvider: TestAuthProvider(),
    );
    system.start();

    var host = TestQuery().rootHost('Test', system);

    var refAttrs = <String, dynamic>{
      'attr1': {'val': 'a1', 'chid': '1:0:0:0'},
      'attr2': {'val': 20, 'chid': '1:0:0:0'},
    };
    var listAttrs = {
      (itemId: 'actor3', name: 'counter-attr'): {'val': 33, 'chid': '1:0:0:0'},
      (itemId: 'actor4', name: 'counter-attr'): {'val': 44, 'chid': '1:0:0:0'},
    };

    var rb = QueryResultBuilder()
      ..val('view1', 'value1', '10:0:0:0')
      ..val('view2', 'value2', '20:0:0:0')
      ..ref('ref1', 'actor2', refAttrs, '100:0:0:0', (rb) {
        rb
          ..val('view3', 'value3', '30:0:0:0')
          ..val('view4', 'value4', '40:0:0:0');
      })
      ..list('list1', listAttrs, '100:0:0:0', (rb) {
        rb
          ..item('xid-1', 'actor3', (rb) {
            rb
              ..val('view5', 'value35', '3500:0:0:0')
              ..val('view6', 'value36', '3610:0:0:0');
          })
          ..item('xid-2', 'actor4', (rb) {
            rb
              ..val('view5', 'value45', '4500:0:0:0')
              ..val('view6', 'value46', '4610:0:0:0');
          });
      });

    host.attach('actor1', rb.build());

    // Don't check for state, it will be loaded only when all views of a query project at least one remote change
    // expect(host.state, ActorQueryState.loaded);

    var view1 = host.children['view1'] as ActorValueViewHost;
    expect(view1.value, 'value1');
    expect(view1.changeId, '10:0:0:0');

    var view2 = host.children['view2'] as ActorValueViewHost;
    expect(view2.value, 'value2');
    expect(view2.changeId, '20:0:0:0');

    var ref = host.children['ref1'] as ActorRefViewHost;
    expect(ref.refId, 'actor2');
    expect(ref.changeId, '100:0:0:0');
    // expect(ref.child.state, ActorQueryState.loaded);
    expect(ref.valueAttr<String>('attr1'), 'a1');
    expect(ref.valueAttr<int>('attr2'), 20);

    var query = ref.child;
    var view3 = query.children['view3'] as ActorValueViewHost;
    expect(view3.value, 'value3');
    expect(view3.changeId, '30:0:0:0');

    var view4 = query.children['view4'] as ActorValueViewHost;
    expect(view4.value, 'value4');
    expect(view4.changeId, '40:0:0:0');

    var list = host.children['list1'] as ActorListViewHost;
    // Check ListItems instead of raw EntityIds
    expect(list.items.length, 2);
    expect(list.items.elementAt(0).key, 'xid-1');
    expect(list.items.elementAt(0).value, 'actor3');
    expect(list.items.elementAt(1).key, 'xid-2');
    expect(list.items.elementAt(1).value, 'actor4');
    expect(list.changeId, '100:0:0:0');
    // expect(list.state, ActorQueryState.loaded);
    expect(list.counterAttr('counter-attr', 0), 33);
    expect(list.counterAttr('counter-attr', 1), 44);
  });
}
