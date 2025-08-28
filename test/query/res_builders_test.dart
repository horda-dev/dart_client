import 'package:horda_client/horda_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('query result builder should build the right result', () {
    final attrs = {
      (itemId: 'actor3', name: 'attr3'): {'val': 'a33', 'chid': '1'},
      (itemId: 'actor3', name: 'attr4'): {'val': 34, 'chid': '1'},
      (itemId: 'actor4', name: 'attr3'): {'val': 'a43', 'chid': '1'},
      (itemId: 'actor4', name: 'attr4'): {'val': 44, 'chid': '1'},
    };

    var rb = QueryResultBuilder()
      ..val('view11', 'value11', '11')
      ..val('view12', 'value12', '12')
      ..ref(
        'ref1',
        'actor2',
        {
          'attr1': {'val': 'a1', 'chid': '1'},
          'attr2': {'val': 20, 'chid': '1'},
        },
        '101',
        (rb) {
          rb
            ..val('view21', 'value21', '21')
            ..val('view22', 'value22', '22');
        },
      )
      ..list('list1', attrs, '201', (rb) {
        rb
          ..item('actor3', (rb) {
            rb
              ..val('view100', 'value3100', '3100')
              ..val('view110', 'value3110', '3110');
          })
          ..item('actor4', (rb) {
            rb
              ..val('view100', 'value4100', '4100')
              ..val('view110', 'value4110', '4110');
          });
      });

    var res = rb.build();

    // root view11

    var v11 = res.views['view11'];
    expect(v11, isNotNull);
    expect(v11, isA<ValueQueryResult>());
    expect(v11!.value, 'value11');
    expect(v11.changeId, '11');

    // root view12

    var v12 = res.views['view12'];
    expect(v12, isNotNull);
    expect(v12, isA<ValueQueryResult>());
    expect(v12!.value, 'value12');
    expect(v12.changeId, '12');

    // ref1

    var ref1 = res.views['ref1'] as RefQueryResult;
    expect(ref1, isNotNull);
    expect(ref1, isA<RefQueryResult>());
    expect(ref1.value, 'actor2');
    expect(ref1.changeId, '101');
    expect(ref1.attrs, {
      'attr1': {'val': 'a1', 'chid': '1'},
      'attr2': {'val': 20, 'chid': '1'},
    });

    // ref1 view21

    var v21 = ref1.query?.views['view21'];
    expect(v21, isNotNull);
    expect(v21, isA<ValueQueryResult>());
    expect(v21!.value, 'value21');
    expect(v21.changeId, '21');

    // ref1 view22

    var v22 = ref1.query?.views['view22'];
    expect(v22, isNotNull);
    expect(v22, isA<ValueQueryResult>());
    expect(v22!.value, 'value22');
    expect(v22.changeId, '22');

    // list1

    var list1 = res.views['list1'] as ListQueryResult;
    expect(list1, isNotNull);
    expect(list1, isA<ListQueryResult>());
    expect(list1.value, ['actor3', 'actor4']);
    expect(list1.changeId, '201');
    expect(list1.attrs, {
      'actor3': {
        'attr3': {'val': 'a33', 'chid': '1'},
        'attr4': {'val': 34, 'chid': '1'},
      },
      'actor4': {
        'attr3': {'val': 'a43', 'chid': '1'},
        'attr4': {'val': 44, 'chid': '1'},
      },
    });

    // list item 0 view100

    var actor3 = list1.items.elementAt(0);
    expect(actor3, isNotNull);

    var v100 = actor3.views['view100'];
    expect(v100, isNotNull);
    expect(v100, isA<ValueQueryResult>());
    expect(v100!.value, 'value3100');
    expect(v100.changeId, '3100');

    // list item 0 view110

    var v110 = actor3.views['view110'];
    expect(v110, isNotNull);
    expect(v110, isA<ValueQueryResult>());
    expect(v110!.value, 'value3110');
    expect(v110.changeId, '3110');

    // list item 1 view100

    var actor4 = list1.items.elementAt(1);
    expect(actor4, isNotNull);

    v100 = actor4.views['view100'];
    expect(v100, isNotNull);
    expect(v100, isA<ValueQueryResult>());
    expect(v100!.value, 'value4100');
    expect(v100.changeId, '4100');

    // list item 1 view110

    v110 = actor4.views['view110'];
    expect(v110, isNotNull);
    expect(v110, isA<ValueQueryResult>());
    expect(v110!.value, 'value4110');
    expect(v110.changeId, '4110');
  });

  test('query result builder should produce json', () {
    final attrs = {
      (itemId: 'actor3', name: 'attr3'): {'val': 'a33', 'chid': '1'},
      (itemId: 'actor3', name: 'attr4'): {'val': 34, 'chid': '1'},
      (itemId: 'actor4', name: 'attr3'): {'val': 'a43', 'chid': '1'},
      (itemId: 'actor4', name: 'attr4'): {'val': 44, 'chid': '1'},
    };

    var rb = QueryResultBuilder()
      ..val('view11', 'value11', '11')
      ..val('view12', 'value12', '12')
      ..ref(
        'ref1',
        'actor2',
        {
          'attr1': {'val': 'a1', 'chid': '1'},
          'attr2': {'val': 20, 'chid': '1'},
        },
        '101',
        (rb) {
          rb
            ..val('view21', 'value21', '21')
            ..val('view22', 'value22', '22');
        },
      )
      ..list('list1', attrs, '201', (rb) {
        rb
          ..item('actor3', (rb) {
            rb
              ..val('view100', 'value3100', '3100')
              ..val('view110', 'value3110', '3110');
          })
          ..item('actor4', (rb) {
            rb
              ..val('view100', 'value4100', '4100')
              ..val('view110', 'value4110', '4110');
          });
      });

    var qr = rb.build();

    expect(qr.toJson(), {
      'view11': {'type': 'val', 'val': 'value11', 'chid': '11'},
      'view12': {'type': 'val', 'val': 'value12', 'chid': '12'},
      'ref1': {
        'type': 'ref',
        'val': 'actor2',
        'chid': '101',
        'attrs': {
          'attr1': {'val': 'a1', 'chid': '1'},
          'attr2': {'val': 20, 'chid': '1'},
        },
        'ref': {
          'view21': {'type': 'val', 'val': 'value21', 'chid': '21'},
          'view22': {'type': 'val', 'val': 'value22', 'chid': '22'},
        },
      },
      'list1': {
        'type': 'list',
        'val': ['actor3', 'actor4'],
        'attrs': {
          'actor3': {
            'attr3': {'val': 'a33', 'chid': '1'},
            'attr4': {'val': 34, 'chid': '1'},
          },
          'actor4': {
            'attr3': {'val': 'a43', 'chid': '1'},
            'attr4': {'val': 44, 'chid': '1'},
          },
        },
        'chid': '201',
        'items': [
          {
            'view100': {'type': 'val', 'val': 'value3100', 'chid': '3100'},
            'view110': {'type': 'val', 'val': 'value3110', 'chid': '3110'},
          },
          {
            'view100': {'type': 'val', 'val': 'value4100', 'chid': '4100'},
            'view110': {'type': 'val', 'val': 'value4110', 'chid': '4110'},
          },
        ],
      },
    });
  });
}
