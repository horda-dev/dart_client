import 'package:horda_client/horda_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: must_be_immutable
class TestModel extends InheritedModelNotifier<String> {
  TestModel({super.key, required super.child});

  var valueA = 'a';
  var valueB = 'b';

  @override
  bool updateShouldNotifyDependent(
    Set<String> changes,
    Set<String> dependencies,
  ) {
    return changes.intersection(dependencies).isNotEmpty;
  }
}

class TestWidgetA extends StatelessWidget {
  const TestWidgetA({super.key});

  @override
  Widget build(BuildContext context) {
    var model = InheritedModelNotifier.inheritFrom<TestModel>(
      context,
      aspect: 'a',
    );

    return Center(child: Text('widget a: ${model.valueA}/${model.valueB}'));
  }
}

class TestWidgetB extends StatelessWidget {
  const TestWidgetB({super.key});

  @override
  Widget build(BuildContext context) {
    var model = InheritedModelNotifier.inheritFrom<TestModel>(
      context,
      aspect: 'b',
    );

    return Center(child: Text('widget b: ${model.valueA}/${model.valueB}'));
  }
}

void main() {
  group('InheritedModelNotifier', () {
    testWidgets('should trigger widget rebuild based on aspect', (
      tester,
    ) async {
      var model = TestModel(
        child: const Column(children: [TestWidgetA(), TestWidgetB()]),
      );

      await tester.pumpWidget(MaterialApp(home: model));

      // wait for bottom sheet animation completion

      var finder = find.text('widget a: a/b');
      expect(finder, findsOneWidget);

      finder = find.text('widget b: a/b');
      expect(finder, findsOneWidget);

      // change aspect 'a'

      model.valueA = 'a1';
      model.aspectChanges.add('a');

      await tester.pumpAndSettle();

      finder = find.text('widget a: a1/b');
      expect(finder, findsOneWidget);

      finder = find.text('widget b: a/b');
      expect(finder, findsOneWidget);

      // change aspect 'b'

      model.valueB = 'b1';
      model.aspectChanges.add('b');

      await tester.pumpAndSettle();

      finder = find.text('widget a: a1/b');
      expect(finder, findsOneWidget);

      finder = find.text('widget b: a1/b1');
      expect(finder, findsOneWidget);
    });
  });
}
