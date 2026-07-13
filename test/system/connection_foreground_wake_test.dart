import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/connection.dart';
import 'package:logging/logging.dart';

const _immediateRetryTimeout = Duration(seconds: 1);

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = _immediateRetryTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);

  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }

    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<WebSocket> _upgrade(HttpRequest request) {
  return WebSocketTransformer.upgrade(
    request,
    protocolSelector: (protocols) => 'horda',
  );
}

void _listen(WebSocket socket) {
  socket.listen((_) {});
}

void main() {
  test('foreground wakes a pending reconnect delay', () async {
    var acceptConnections = true;
    late WebSocket initialSocket;

    final backoffStarted = Completer<void>();
    final previousRootLogLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final server = await HttpServer.bind('localhost', 0);
    final serverSub = server.listen((request) async {
      if (!acceptConnections) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }

      final socket = await _upgrade(request);
      initialSocket = socket;
      _listen(socket);
    });

    final system = TestHordaClientSystem();
    final conn = WebSocketConnection(
      system,
      'ws://localhost:${server.port}',
      'test-api-key',
    );
    final logSub = conn.logger.onRecord.listen((record) {
      if (record.message == 'reconnecting after 2 seconds...' &&
          !backoffStarted.isCompleted) {
        backoffStarted.complete();
      }
    });

    addTearDown(() async {
      conn.close();
      await logSub.cancel();
      await serverSub.cancel();
      await server.close(force: true);
      Logger.root.level = previousRootLogLevel;
    });

    await conn.open();
    expect(conn.value, isA<ConnectionStateConnected>());

    acceptConnections = false;
    await initialSocket.close();

    await backoffStarted.future.timeout(_immediateRetryTimeout);

    acceptConnections = true;
    conn.resetReconnectBackoff();

    await _waitUntil(
      () => conn.value is ConnectionStateReconnected,
    );
  });

  test('foreground during a connection attempt retries immediately', () async {
    var connectionCount = 0;
    late WebSocket initialSocket;

    final reconnectAttemptStarted = Completer<void>();
    final rejectReconnectAttempt = Completer<void>();
    final immediateRetryReceived = Completer<void>();

    final server = await HttpServer.bind('localhost', 0);
    final serverSub = server.listen((request) async {
      connectionCount += 1;

      if (connectionCount == 1) {
        final socket = await _upgrade(request);
        initialSocket = socket;
        _listen(socket);
        return;
      }

      if (connectionCount == 2) {
        reconnectAttemptStarted.complete();
        await rejectReconnectAttempt.future;
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }

      final socket = await _upgrade(request);
      _listen(socket);
      immediateRetryReceived.complete();
    });

    final system = TestHordaClientSystem();
    final conn = WebSocketConnection(
      system,
      'ws://localhost:${server.port}',
      'test-api-key',
    );

    addTearDown(() async {
      conn.close();
      await serverSub.cancel();
      await server.close(force: true);
    });

    await conn.open();
    expect(conn.value, isA<ConnectionStateConnected>());

    await initialSocket.close();
    await reconnectAttemptStarted.future.timeout(_immediateRetryTimeout);

    conn.resetReconnectBackoff();
    rejectReconnectAttempt.complete();

    await immediateRetryReceived.future.timeout(_immediateRetryTimeout);
    await _waitUntil(
      () => conn.value is ConnectionStateReconnected,
    );
  });
}
