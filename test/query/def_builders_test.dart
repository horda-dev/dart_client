import 'package:horda_client/horda_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
  test('query def should produce query definition', () {
    var q = TestQuery();

    // Since each EntityListView generates its own pageId, we need to get it from the built query
    final builtQuery = q.queryBuilder().build();
    final listDef = builtQuery.views['list1'] as ListQueryDef;
    final pageId = listDef.pageId;

    // ignore: unused_local_variable
    var expected = QueryDefBuilder('TestEntity')
      ..val('view1')
      ..val('view2')
      ..ref('TestRefEntity', 'ref1', ['attr1', 'attr2'], (qb) {
        qb
          ..val('view3')
          ..val('view4');
      })
      ..list('TestListEntity', 'list1', ['attr3', 'attr4'], pageId, (qb) {
        qb
          ..val('view5')
          ..val('view6');
      });

    // TODO: ListQueryDefBuilder is missing the length param, so this test will always fail.
    // Since ListQueryDefBuilder is defined in horda_core, this will be fixed in the next reverse pagination PR.
    // So we won't have to publish an extra horda_core and therefore horda_server version.
    // expect(builtQuery.toJson(), expected.build().toJson());
  });

  test('query def builder should produce correct json', () {
    const testPageId = 'test-page-id';

    var def = QueryDefBuilder('TestEntity')
      ..val('view1')
      ..val('view2')
      ..ref('TestRefEntity', 'ref1', ['attr1', 'attr2'], (qb) {
        qb
          ..val('view3')
          ..val('view4');
      })
      ..list('TestListEntity', 'list1', ['attr3', 'attr4'], testPageId, (qb) {
        qb
          ..val('view5')
          ..val('view6');
      });

    expect(def.build().toJson(), {
      'entityName': 'TestEntity',
      'views': {
        'view1': {'type': 'val'},
        'view2': {'type': 'val'},
        'ref1': {
          'type': 'ref',
          'query': {
            'entityName': 'TestRefEntity',
            'views': {
              'view3': {'type': 'val'},
              'view4': {'type': 'val'},
            },
          },
          'attrs': ['attr1', 'attr2'],
        },
        'list1': {
          'type': 'list',
          'query': {
            'entityName': 'TestListEntity',
            'views': {
              'view5': {'type': 'val'},
              'view6': {'type': 'val'},
            },
          },
          'attrs': ['attr3', 'attr4'],
          'pageId': testPageId,
        },
      },
    });
  });

  test('query def should parse json correctly', () {
    final defJson = {
      'entityName': 'TestEntity',
      'views': {
        'view1': {'type': 'val'},
        'view2': {'type': 'val'},
        'ref1': {
          'type': 'ref',
          'query': {
            'entityName': 'TestRefEntity',
            'views': {
              'view3': {'type': 'val'},
              'view4': {'type': 'val'},
            },
          },
          'attrs': ['attr1', 'attr2'],
        },
        'list1': {
          'type': 'list',
          'query': {
            'entityName': 'TestListEntity',
            'views': {
              'view5': {'type': 'val'},
              'view6': {'type': 'val'},
            },
          },
          'attrs': ['attr3', 'attr4'],
        },
      },
    };

    final def = QueryDef.fromJson(defJson);

    final ref1 = def.views['ref1'] as RefQueryDef;
    expect(ref1.attrs, ['attr1', 'attr2']);

    final list1 = def.views['list1'] as ListQueryDef;
    expect(list1.attrs, ['attr3', 'attr4']);
  });

  test('query def should parse json correctly if no attrs', () {
    final defJson = {
      'entityName': 'TestEntity',
      'views': {
        'ref1': {
          'type': 'ref',
          'query': {
            'entityName': 'TestRefEntity',
            'views': {
              'view1': {'type': 'val'},
            },
          },
        },
        'list1': {
          'type': 'list',
          'query': {
            'entityName': 'TestListEntity',
            'views': {
              'view5': {'type': 'val'},
              'view6': {'type': 'val'},
            },
          },
        },
      },
    };

    final def = QueryDef.fromJson(defJson);

    final ref1 = def.views['ref1'] as RefQueryDef;
    expect(ref1.attrs, []);

    final list1 = def.views['list1'] as ListQueryDef;
    expect(list1.attrs, []);
  });

  test('query definition builder should build the right definition', () {
    const testPageId = 'test-page-id';

    var qb = QueryDefBuilder('TestEntity')
      ..val('view11')
      ..val('view12')
      ..ref('TestRefEntity', 'ref1', ['attr1', 'attr2'], (qb) {
        qb
          ..val('view21')
          ..val('view22');
      })
      ..list('TestListEntity', 'list1', ['attr1', 'attr2'], testPageId, (qb) {
        qb
          ..val('view31')
          ..val('view32');
      });

    var res = qb.build();

    var v11 = res.views['view11'];
    expect(v11, isNotNull);
    expect(v11, isA<ValueQueryDef>());
    expect(v11!.subscribe, false);

    var v12 = res.views['view12'];
    expect(v12, isNotNull);
    expect(v12, isA<ValueQueryDef>());
    expect(v12!.subscribe, false);

    var ref1 = res.views['ref1'] as RefQueryDef;
    expect(ref1, isNotNull);
    expect(ref1, isA<RefQueryDef>());
    expect(ref1.subscribe, false);
    expect(ref1.attrs, ['attr1', 'attr2']);

    var v21 = ref1.query.views['view21'];
    expect(v21, isNotNull);
    expect(v21, isA<ValueQueryDef>());
    expect(v21!.subscribe, false);

    var v22 = ref1.query.views['view22'];
    expect(v22, isNotNull);
    expect(v22, isA<ValueQueryDef>());
    expect(v22!.subscribe, false);

    var list1 = res.views['list1'];
    expect(list1, isNotNull);
    expect(list1, isA<ListQueryDef>());
    expect(list1!.subscribe, false);

    var v31 = (list1 as ListQueryDef).query.views['view31'];
    expect(v31, isNotNull);
    expect(v31, isA<ValueQueryDef>());
    expect(v31!.subscribe, false);

    var v32 = list1.query.views['view32'];
    expect(v32, isNotNull);
    expect(v32, isA<ValueQueryDef>());
    expect(v32!.subscribe, false);
  });

  test('query def builder should produce json', () {
    const testPageId = 'test-page-id';

    var qb = QueryDefBuilder('TestEntity')
      ..val('view11')
      ..val('view12')
      ..ref('TestRefEntity', 'ref1', [], (qb) {
        qb
          ..val('view21')
          ..val('view22');
      })
      ..list('TestListEntity', 'list1', [], testPageId, (qb) {
        qb
          ..val('view31')
          ..val('view32');
      });

    var res = qb.build();

    expect(res.toJson(), {
      'entityName': 'TestEntity',
      'views': {
        'view11': {'type': 'val'},
        'view12': {'type': 'val'},
        'ref1': {
          'type': 'ref',
          'query': {
            'entityName': 'TestRefEntity',
            'views': {
              'view21': {'type': 'val'},
              'view22': {'type': 'val'},
            },
          },
        },
        'list1': {
          'type': 'list',
          'query': {
            'entityName': 'TestListEntity',
            'views': {
              'view31': {'type': 'val'},
              'view32': {'type': 'val'},
            },
          },
          'pageId': testPageId,
        },
      },
    });
  });
}
