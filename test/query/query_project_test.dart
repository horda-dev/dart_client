import 'package:horda_client/horda_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('project should work as expected', (WidgetTester tester) async {
    // final system = FluirClientSystem(
    //   LoggedInConfig(
    //     url: 'ws://0.0.0.0:8080/ws',
    //     authToken: 'user1',
    //   ),
    // );

    // // Use runAsync due to async operations in system.start
    // await tester.runAsync(() async {
    //   system.start();
    //   await Future.delayed(const Duration(milliseconds: 500));
    //   print('Connection state: ${system.conn.value.runtimeType}');
    // });

    // expect(system.conn.value, TypeMatcher<ConnectionStateConnected>());

    // await tester.pumpWidget(
    //   FluirSystemProvider(
    //     system: system,
    //     child: RunApp(),
    //   ),
    // );

    // BuildContext context = tester.element(find.byType(TestApp));

    // // expect(find.text('Build loading'), findsOneWidget);

    // // // do {
    // await tester.pumpAndSettle(const Duration(seconds: 3));
    // context = tester.element(find.byType(TestApp));

    // print(context.query<TestQuery>().state());
    // print(context.query<TestQuery>().ref((q) => q.ref1).state());
    // // print(context.query<TestQuery>().listItems((q) => q.list1));
    // // // } while (context.query<TestQuery>().state() == ActorQueryState.created);
    // // // final testQuery = context.query<TestQuery>();

    // // // final stateTestQuery = testQuery.state();
    // // expect(ActorQueryState.created, context.query<TestQuery>().state());

    // await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}

class RunApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var app = TestApp();

    if (context.hordaAuthUserId == null) {
      throw Exception('user id is null');
    }

    return context.runEntityQuery(
      entityId: 'user1',
      query: TestQuery(),
      child: app,
    );
  }
}

class TestApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var state = context.query<TestQuery>().state();
    print(context.query<TestQuery>().state());
    print(context.query<TestQuery>().ref((q) => q.ref1).value((q) => q.view3));
    switch (state) {
      case EntityQueryState.created:
        return _buildLoading(context);
      case EntityQueryState.error:
      case EntityQueryState.stopped:
        return _buildError(context);
      case EntityQueryState.loaded:
        return _buildLoaded(context);
    }
  }

  Widget _buildLoading(BuildContext context) {
    return MaterialApp(home: Scaffold(body: Text('Build loading')));
  }

  Widget _buildError(BuildContext context) {
    return MaterialApp(home: Scaffold(body: Text('Build error')));
  }

  Widget _buildLoaded(BuildContext context) {
    return MaterialApp(home: Scaffold(body: Text('Build loaded')));
  }
}

class TestQuery extends EntityQuery {
  var list1 = EntityListView('list1', query: TestListQuery());

  var ref1 = EntityRefView('ref1', query: TestRefQuery());

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(list1)
      ..add(ref1);
  }
}

class TestListQuery extends EntityQuery {
  var view1 = EntityValueView<String>('view1');

  var view2 = EntityValueView<String>('view2');

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(view1)
      ..add(view2);
  }
}

class TestRefQuery extends EntityQuery {
  var view3 = EntityValueView<String>('view3');

  var view4 = EntityValueView<String>('view4');

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(view3)
      ..add(view4);
  }
}
