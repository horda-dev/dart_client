import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'message_store.dart';
import 'provider.dart';

part 'system.g.dart';

class FluirClientSystem {
  FluirClientSystem(
    this.connectionConfig,
    this.authProvider, {
    this.analyticsService,
    this.errorTrackingService,
  }) : authState = ValueNotifier<FluirAuthState>(
          connectionConfig is IncognitoConfig
              ? AuthStateIncognito()
              : AuthStateValidating(),
        ) {
    logger = Logger('Fluir.System');
    conn = WebSocketConnection(this, connectionConfig);
    messageStore = ClientMessageStore(this, conn);
  }

  ConnectionConfig connectionConfig;

  final AuthProvider authProvider;

  final AnalyticsService? analyticsService;

  final ErrorTrackingService? errorTrackingService;

  late final ClientMessageStore messageStore;

  late Connection conn;

  late final Logger logger;

  final ValueNotifier<FluirAuthState> authState;

  void start() {
    logger.fine('starting client system...');

    kRegisterFluirMessage();

    conn.open();

    logger.info('client system started');
  }

  void stop() {
    conn.close();
  }

  void reopen(ConnectionConfig config) {
    conn.reopen(config);
  }

  void changeAuthState(String? userId) {
    if (userId == null) {
      this.authState.value = AuthStateIncognito();
    } else {
      this.authState.value = AuthStateLoggedIn(userId: userId);
    }
  }

  void sendRemote(String actorName, ActorId workerId, RemoteCommand cmd) {
    logger.fine('sending remote command $cmd to $workerId...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        actorId: workerId,
        actorName: actorName,
      ),
    );

    try {
      conn.send(actorName, workerId, cmd);
    } catch (e) {
      logger.severe('send remote $cmd to $workerId failed with $e');
      return;
    }

    logger.info('sent remote $cmd to $workerId');
  }

  Future<RemoteEvent> callRemote(
    String actorName,
    ActorId workerId,
    RemoteCommand cmd,
  ) async {
    logger.fine('calling remote command $cmd to $workerId...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        actorId: workerId,
        actorName: actorName,
      ),
    );

    final res = await conn.call(
      actorName,
      workerId,
      cmd,
      const Duration(seconds: 10),
    );

    logger.info('called command $cmd to $workerId');

    return res;
  }

  /// Sends a [RemoteEvent] to the server and returns a [FlowResult2]
  /// after the event is handled by [Flow].
  Future<FlowResult2> dispatchEvent(RemoteEvent event) async {
    logger.fine('dispatching event $event to...');
    analyticsService?.reportMessage(
      event,
      DispatchLabels(
        senderId: _senderId,
      ),
    );

    final res = await conn.dispatchEvent(
      event,
      const Duration(seconds: 10),
    );

    logger.info('dispatched event $event');

    return res;
  }

  void publishChange(ChangeEnvelop2 env, {bool save = true}) {
    messageStore.publishChange(env);
  }

  Future<QueryResult2> query({
    required String actorId,
    required String name,
    required QueryDef def,
  }) {
    return conn.query(
      actorId: actorId,
      name: name,
      def: def,
    );
  }

  Future<void> subscribeViews(Iterable<ActorViewSub2> subs) async {
    final readyToSub = _incViewSubCount(subs);

    final alreadySubbed = subs.toSet().difference(readyToSub.toSet());

    // If there are two queries which use the same view, one of them will subscribe this view and it will receive
    // an empty/non-empty envelope from remote history. Then in the second query the same view won't be able to
    // report as ready in the same way, since the view is already subbed, it'll have to wait for a non-history
    // remote envelop which might or might not come.
    //
    // Therefore manually publish an empty ChangeEnvelop2 to let view report as ready.
    for (final sub in alreadySubbed) {
      logger.info('$sub is already subbed, publishing empty change envelop...');
      publishChange(
        ChangeEnvelop2.empty(key: sub.id, name: sub.name),
      );
    }

    if (readyToSub.isEmpty) {
      logger.info('No views can currently be subscribed. Skipping...');
      return;
    }

    logger.fine('Ready to sub: $readyToSub');

    try {
      await conn.subscribeViews(readyToSub);

      logger.info('subscribed to ${readyToSub.length} views');
    } catch (e) {
      logger.severe('subscribe views error $e');

      logger.warning('Decrementing host count due to unsub error...');
      _decViewSubCount(subs);
    }
  }

  Future<void> unsubscribeViews(Iterable<ActorViewSub2> subs) async {
    final readyToUnsub = _decViewSubCount(subs);

    if (readyToUnsub.isEmpty) {
      logger.info('No views can currently be unsubscribed. Skipping...');
      return;
    }

    logger.fine('Ready to unsub: $readyToUnsub');

    try {
      await conn.unsubscribeViews(readyToUnsub);

      logger.info('unsubscribed from ${readyToUnsub.length} views');
    } catch (e) {
      logger.severe('unsubscribe views error $e');

      logger.warning('Re-incrementing host count due to unsub error...');
      _incViewSubCount(subs);
    }
  }

  /// Returns the number of the latest stored version of a view or attribute.
  /// Will return null if view has no locally stored history.
  String? latestStoredChangeIdOf({
    required String id,
    required String name,
  }) {
    return messageStore.latestStoredChangeId(
      id: id,
      name: name,
    );
  }

  /// Returns a [Stream] of [ChangeEnvelop2]s which includes both change history and future changes.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Stream<ChangeEnvelop2> changes({
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changes(
      id: id,
      name: name,
      startAt: startAt,
    );
  }

  /// Returns an [Iterable] of [ChangeEnvelop2]s from view(or attribute)'s change history,
  /// or an empty [Iterable] if there's no history.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Iterable<ChangeEnvelop2> changeHistory({
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changeHistory(
      id: id,
      name: name,
      startAt: startAt,
    );
  }

  /// Returns a [Stream] of [ChangeEnvelop2]s which emits future changes which are coming from the server.
  Stream<ChangeEnvelop2> futureChanges({
    required String id,
    required String name,
  }) {
    return messageStore.futureChanges(
      id: id,
      name: name,
    );
  }

  /// Clears local storage of [Change]s and [RemoteEvent]s.
  void clearStore() {
    messageStore.clear();
  }

  /// Increments the host count for every provided [ActorViewSub2] and returns [ActorViewSub2]s which should be subscribed.
  Iterable<ActorViewSub2> _incViewSubCount(Iterable<ActorViewSub2> subs) {
    final viewsToSub = <ActorViewSub2>[];

    for (final sub in subs) {
      final subKey = '${sub.id}/${sub.name}';

      if (_viewSubCount.containsKey(subKey)) {
        final oldHostCount = _viewSubCount[subKey]!;
        _viewSubCount[subKey] = oldHostCount + 1;

        logger.fine(
          'Host count INCREMENTED from $oldHostCount to ${_viewSubCount[subKey]} for sub: $subKey',
        );
      } else {
        _viewSubCount[subKey] = 1;
        viewsToSub.add(sub);

        logger.fine('Host count now TRACKING for sub: $subKey');
      }
    }

    return viewsToSub;
  }

  /// Decrements the host count for every provided [ActorViewSub2] and returns [ActorViewSub2]s which should to be unsubscribed.
  Iterable<ActorViewSub2> _decViewSubCount(Iterable<ActorViewSub2> subs) {
    final viewsToUnsub = <ActorViewSub2>[];

    for (final sub in subs) {
      final subKey = '${sub.id}/${sub.name}';

      if (_viewSubCount.containsKey(subKey)) {
        final oldHostCount = _viewSubCount[subKey]!;
        _viewSubCount[subKey] = oldHostCount - 1;

        logger.fine(
          'Host count DECREMENTED from $oldHostCount to ${_viewSubCount[subKey]} for sub: $subKey',
        );

        if (_viewSubCount[subKey]! < 1) {
          _viewSubCount.remove(subKey);
          viewsToUnsub.add(sub);

          logger.fine(
            'Host count now UNTRACKED for sub: $subKey, should be ready to unsub',
          );
        }
      } else {
        logger.warning(
          'Decrementing host count for an untracked sub $subKey which should\'ve been unsubbed already.',
        );
        continue;
      }
    }

    return viewsToUnsub;
  }

  String get _senderId {
    final authState = this.authState.value;

    return switch (authState) {
      AuthStateIncognito() => 'incognito',
      AuthStateValidating() => 'validating',
      AuthStateLoggedIn() => authState.userId,
    };
  }

  /// Stores the count of subs per view.
  /// - Key - view subscription key: `'actorId/viewName'`
  /// - Value - count of hosts which depend on a view subscription
  final _viewSubCount = <String, int>{};
}

class TestFluirClientSystem extends FluirClientSystem {
  TestFluirClientSystem()
      : super(
          IncognitoConfig(url: '', apiKey: ''),
          TestAuthProvider(),
        );

  void start() {
    // noop
  }

  void stop() {
    // noop
  }
}

abstract class AuthProvider {
  Future<String?> getIdToken();
}

abstract class ErrorTrackingService {
  void reportError(Object e, [StackTrace? stack]);
}

abstract class AnalyticsService {
  void reportMessage(Message msg, [MessageLabels? labels]);
}

abstract class MessageLabels {
  Map<String, dynamic> toJson();
}

@JsonSerializable(createFactory: false)
class SendCallLabels implements MessageLabels {
  SendCallLabels({
    required this.senderId,
    required this.actorId,
    required this.actorName,
  });

  final String senderId;
  final String actorId;
  final String actorName;

  @override
  Map<String, dynamic> toJson() {
    return _$SendCallLabelsToJson(this);
  }
}

@JsonSerializable(createFactory: false)
class DispatchLabels implements MessageLabels {
  DispatchLabels({required this.senderId});

  final String senderId;

  @override
  Map<String, dynamic> toJson() {
    return _$DispatchLabelsToJson(this);
  }
}

class TestAuthProvider implements AuthProvider {
  Future<String?> getIdToken() {
    return Future.value('test-id-token');
  }
}
