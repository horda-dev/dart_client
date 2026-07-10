import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/connection.dart';
import 'package:horda_client/src/query.dart';
import 'package:logging/logging.dart';

/// Maximum time for an interrupted operation to settle after reconnecting.
const _settleTimeout = Duration(seconds: 2);

/// Minimal child query for ref projections.
class _SpeechTextQuery extends EntityQuery {
  @override
  String get entityName => 'SpeechEntity';

  final text = EntityValueView<String>('text');

  @override
  void initViews(EntityQueryGroup views) {
    views.add(text);
  }
}

/// Minimal child query for list projections.
class _UserNameQuery extends EntityQuery {
  @override
  String get entityName => 'UserEntity';

  final userName = EntityValueView<String>('name');

  @override
  void initViews(EntityQueryGroup views) {
    views.add(userName);
  }
}

/// Parent query with a replaceable speech ref.
class _ThreadLiveSpeechQuery extends EntityQuery {
  @override
  String get entityName => 'ThreadEntity';

  final liveSpeech = EntityRefView(
    'liveSpeech',
    nullable: true,
    query: _SpeechTextQuery(),
  );

  @override
  void initViews(EntityQueryGroup views) {
    views.add(liveSpeech);
  }
}

/// Parent query with a removable user list item.
class _ThreadWaitListQuery extends EntityQuery {
  @override
  String get entityName => 'ThreadEntity';

  final waitList = EntityListView('waitList', query: _UserNameQuery());

  @override
  void initViews(EntityQueryGroup views) {
    views.add(waitList);
  }
}

/// Runs a real client against a server that drops its first query on demand.
class _DroppedQueryFixture {
  _DroppedQueryFixture._(this._server, this.system);

  final HttpServer _server;
  final HordaClientSystem system;

  late final StreamSubscription<HttpRequest> _serverSub;
  final _firstQueryReceived = Completer<void>();
  final _dropFirstConnection = Completer<void>();
  final _logger = Logger('DroppedQueryFixture');
  var _isFirstQuery = true;

  static Future<_DroppedQueryFixture> start() async {
    final server = await HttpServer.bind('localhost', 0);
    final system = HordaClientSystem(
      url: 'ws://localhost:${server.port}',
      apiKey: 'test-api-key',
    );
    final fixture = _DroppedQueryFixture._(server, system);
    fixture._serverSub = server.listen(fixture._handleRequest);

    await system.start();

    return fixture;
  }

  Future<void> get firstQueryReceived => _firstQueryReceived.future;

  Future<void> dropFirstConnection() async {
    _dropFirstConnection.complete();
    await _waitUntil(() => system.conn.value is ConnectionStateReconnected);
  }

  Future<void> dispose() async {
    system.stop();
    await _serverSub.cancel();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => 'horda',
    );

    socket.listen((data) async {
      final box = WsMessageBox.decodeJson(data as String, _logger);

      if (box.msg is UnsubscribeViewsWsMsg) {
        socket.add(
          WsMessageBox(
            id: box.id,
            msg: UnsubscribeViewsResWsMsg(),
          ).encodeJson(_logger),
        );
        return;
      }

      if (box.msg is! QueryAndSubscribeWsMsg) {
        return;
      }

      if (_isFirstQuery) {
        // Hold the first query until the test starts its waiting operation.
        _isFirstQuery = false;
        _firstQueryReceived.complete();
        await _dropFirstConnection.future;
        await socket.close();
        return;
      }

      _sendQueryResult(socket, box);
    });
  }

  void _sendQueryResult(WebSocket socket, WsMessageBox request) {
    final query = request.msg as QueryAndSubscribeWsMsg;
    final result = QueryResultBuilder();

    for (final entry in query.def.views.entries) {
      if (entry.value is ValueQueryDef) {
        result.val(entry.key, 'value', '1:0:0:0');
      }
    }

    socket.add(
      WsMessageBox(
        id: request.id,
        msg: QueryResultWsMsg(result: result.build()),
      ).encodeJson(_logger),
    );
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
    'ref projection resumes after an intersecting query connection drops',
    () async {
      final fixture = await _DroppedQueryFixture.start();
      addTearDown(fixture.dispose);

      // Start an in-flight query that shares the ref child query.
      final queryDef = _SpeechTextQuery().queryBuilder().build();
      final failedQuery = expectLater(
        fixture.system.queryAndSubscribe(
          entityId: 'other-speech',
          def: queryDef,
        ),
        throwsA(isA<ConnectionClosedException>()),
      );
      await fixture.firstQueryReceived;

      // Change the ref while its child unsubscribe waits for that query.
      final host = _ThreadLiveSpeechQuery().rootHost(
        'Conversation',
        fixture.system,
      );
      final refHost = host.children['liveSpeech'] as ActorRefViewHost;
      final projection = refHost.project(
        'thread-1',
        'liveSpeech',
        RefViewChanged('speech-b'),
        'speech-a',
      );

      // Drop the socket after projection has started waiting.
      await fixture.dropFirstConnection();
      await Future.wait([failedQuery, projection]).timeout(_settleTimeout);
    },
  );

  test(
    'list projection resumes after an intersecting query connection drops',
    () async {
      final fixture = await _DroppedQueryFixture.start();
      addTearDown(fixture.dispose);

      // Start an in-flight query that shares the list item child query.
      final queryDef = _UserNameQuery().queryBuilder().build();
      final failedQuery = expectLater(
        fixture.system.queryAndSubscribe(
          entityId: 'other-user',
          def: queryDef,
        ),
        throwsA(isA<ConnectionClosedException>()),
      );
      await fixture.firstQueryReceived;

      // Attach one list item so its removal must stop a child query host.
      final host = _ThreadWaitListQuery().rootHost(
        'Conversation',
        fixture.system,
      );
      final result = QueryResultBuilder()
        ..list('waitList', {}, '1:0:0:0', 'waitlist-page', (list) {
          list.item(1.0, 'user-1', (item) {
            item.val('name', 'Alice', '1:0:0:0');
          });
        });

      host.attach('thread-1', result.build());
      fixture.system.finalizeQuerySubscriptions(
        host.query.queryBuilder().build(),
        host.subscriptions(),
      );

      final waitListHost = host.children['waitList'] as ActorListViewHost;
      final projection = waitListHost.project(
        'thread-1',
        'waitList',
        ListPageItemRemoved(pageId: waitListHost.pageId, pos: 1.0),
        waitListHost.value as List<ListItem>,
      );

      // Drop the socket after projection has started waiting.
      await fixture.dropFirstConnection();
      await Future.wait([failedQuery, projection]).timeout(_settleTimeout);
    },
  );
}
