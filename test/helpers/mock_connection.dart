import 'package:flutter/foundation.dart';
import 'package:horda_client/horda_client.dart';
import 'package:horda_client/src/connection.dart';
import 'package:logging/logging.dart';

/// Mock connection that tracks subscription calls for testing
class MockConnection extends ValueNotifier<HordaConnectionState>
    implements Connection {
  MockConnection()
    : logger = Logger('MockConnection'),
      super(ConnectionStateConnected());

  final Logger logger;

  @override
  String get url => 'ws://test';

  @override
  String get apiKey => 'test-api-key';

  final unsubscribeCallLog = <List<ActorViewSub>>[];

  @override
  Future<void> open() async {}

  @override
  void close() {}

  @override
  Future<void> reopen() async {}

  @override
  Future<QueryResult> query({
    required String actorId,
    required QueryDef def,
  }) async {
    return _createMockResult(actorId, def);
  }

  @override
  Future<QueryResult> queryAndSubscribe({
    required String actorId,
    required QueryDef def,
  }) async {
    logger.info('queryAndSubscribe called for $actorId');
    return _createMockResult(actorId, def);
  }

  @override
  Future<void> subscribeViews(Iterable<ActorViewSub> subs) async {
    // Deprecated - no-op
    logger.info('subscribeViews called (deprecated)');
  }

  @override
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs) async {
    logger.info('unsubscribeViews called with ${subs.length} subs');
    unsubscribeCallLog.add(subs.toList());
  }

  @override
  Future<void> sendEntity(
    String actorName,
    String to,
    RemoteCommand cmd,
  ) async {}

  @override
  Future<E> callEntity<E extends RemoteEvent>(
    String actorName,
    String to,
    RemoteCommand cmd,
    FromJsonFun<E> fac,
    Duration timeout,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ProcessResult> runProcess(RemoteEvent event, Duration timeout) async {
    throw UnimplementedError();
  }

  QueryResult _createMockResult(String actorId, QueryDef def) {
    final builder = QueryResultBuilder();
    _buildViewsFromDef(actorId, def, builder);
    return builder.build();
  }

  /// Recursively builds query result views based on the query definition
  void _buildViewsFromDef(
    String actorId,
    QueryDef def,
    QueryResultBuilder builder,
  ) {
    for (var entry in def.views.entries) {
      final viewName = entry.key;
      final viewDef = entry.value;

      if (viewDef is ValueQueryDef) {
        // Create mock value based on view name
        final mockValue = _getMockValue(viewName);
        builder.val(viewName, mockValue, '1:0:0:0');
      } else if (viewDef is RefQueryDef) {
        // Create mock ref view with nested query
        final refId = '$actorId-$viewName-ref';
        builder.ref(viewName, refId, {}, '1:0:0:0', (refBuilder) {
          _buildViewsFromDef(refId, viewDef.query, refBuilder);
        });
      } else if (viewDef is ListQueryDef) {
        // Create mock list view with nested query items
        builder.list(viewName, {}, '1:0:0:0', 'mock-page-id', (listBuilder) {
          // Create 2 mock items with XID keys
          for (var i = 0; i < 2; i++) {
            final xidKey = 'xid-$actorId-$viewName-$i';
            final itemId = '$actorId-$viewName-item$i';
            listBuilder.item(xidKey, itemId, (itemBuilder) {
              _buildViewsFromDef(itemId, viewDef.query, itemBuilder);
            });
          }
        });
      }
    }
  }

  /// Returns a mock value based on the view name
  dynamic _getMockValue(String viewName) {
    // Return appropriate mock values based on common view names
    if (viewName.contains('name')) return 'test-name';
    if (viewName == 'view1') return 'test-value';
    if (viewName == 'view2') return 42;
    if (viewName == 'itemValue') return 'mock-item-value';

    // Default: return string based on view name
    return 'mock-$viewName';
  }
}
