import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/connection.dart';
import 'package:logging/logging.dart';

/// Minimal query for exercising query-and-subscribe.
class _FakeUserNameQuery extends EntityQuery {
  @override
  String get entityName => 'UserEntity';

  final userName = EntityValueView<String>('name');

  @override
  void initViews(EntityQueryGroup views) {
    views.add(userName);
  }
}

/// Waits for [condition] or fails after [timeout].
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }

    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'in-flight requests fail when their connection drops and reconnects',
    () async {
      var querySubReceived = false;

      final server = await HttpServer.bind('localhost', 0);
      final serverSub = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          // WebSocketConnection requires this subprotocol.
          protocolSelector: (protocols) => 'horda',
        );

        socket.listen((data) {
          final box = WsMessageBox.decodeJson(data as String, Logger('test'));

          if (box.msg is QueryAndSubscribeWsMsg && !querySubReceived) {
            // Close on the first request without replying.
            querySubReceived = true;
            socket.close();
          }
        });
      });

      addTearDown(() async {
        await serverSub.cancel();
        await server.close(force: true);
      });

      final system = TestHordaClientSystem();
      final conn = WebSocketConnection(
        system,
        'ws://localhost:${server.port}',
        'test-api-key',
      );
      addTearDown(conn.close);

      await conn.open();
      expect(conn.value, isA<ConnectionStateConnected>());

      final def = _FakeUserNameQuery().queryBuilder().build();
      final requestResult = expectLater(
        conn.queryAndSubscribe(actorId: 'user-1', def: def),
        throwsA(isA<ConnectionException>()),
      );

      await _waitUntil(() => querySubReceived);
      await _waitUntil(() => conn.value is ConnectionStateReconnected);
      await requestResult;
    },
  );
}
