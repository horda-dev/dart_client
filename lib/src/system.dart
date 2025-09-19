import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:horda_core/horda_core.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'message_store.dart';
import 'provider.dart';

part 'system.g.dart';

/// Main client system for managing connection and communication with Horda backend.
///
/// The client system handles:
/// - WebSocket connection management
/// - Authentication state management
/// - Entity queries and real-time subscriptions
/// - Command dispatch and event handling
/// - Message storage and change history
///
/// Example:
/// ```dart
/// final system = HordaClientSystem(
///   IncognitoConfig(url: url, apiKey: apiKey),
///   NoAuth(),
/// );
/// system.start();
/// ```
class HordaClientSystem {
  HordaClientSystem({
    required String url,
    required String apiKey,
    this.authProvider,
    this.analyticsService,
    this.errorTrackingService,
  }) : authState = ValueNotifier<HordaAuthState>(
         authProvider == null ? AuthStateIncognito() : AuthStateValidating(),
       ) {
    logger = Logger('Fluir.System');
    conn = WebSocketConnection(this, url, apiKey);
    messageStore = ClientMessageStore(this, conn);
  }

  final AuthProvider? authProvider;

  final AnalyticsService? analyticsService;

  final ErrorTrackingService? errorTrackingService;

  late final ClientMessageStore messageStore;

  late Connection conn;

  late final Logger logger;

  final ValueNotifier<HordaAuthState> authState;

  Future<void> start() async {
    logger.fine('starting client system...');

    kRegisterFluirMessage();

    await conn.open();

    logger.info('client system started');
  }

  void stop() {
    conn.close();
  }

  Future<void> reopen() async {
    await conn.reopen();
  }

  /// Changes the authentication state of the Horda client system.
  ///
  /// This method is intended for internal use by the SDK and should not be called
  /// directly by importing clients. The SDK manages the authentication state
  /// automatically based on connection events and authentication provider responses.
  @internal
  void changeAuthState(String? userId) {
    if (userId == null) {
      this.authState.value = AuthStateIncognito();
    } else {
      this.authState.value = AuthStateLoggedIn(userId: userId);
    }
  }

  void sendRemote(String entityName, EntityId entityId, RemoteCommand cmd) {
    logger.fine('sending remote command $cmd to $entityId...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        entityId: entityId,
        entityName: entityName,
      ),
    );

    try {
      conn.send(entityName, entityId, cmd);
    } catch (e) {
      logger.severe('send remote $cmd to $entityId failed with $e');
      return;
    }

    logger.info('sent remote $cmd to $entityId');
  }

  Future<RemoteEvent> callRemote(
    String entityName,
    EntityId entityId,
    RemoteCommand cmd,
  ) async {
    logger.fine('calling remote command $cmd to $entityId...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        entityId: entityId,
        entityName: entityName,
      ),
    );

    final res = await conn.call(
      entityName,
      entityId,
      cmd,
      const Duration(seconds: 10),
    );

    logger.info('called command $cmd to $entityId');

    return res;
  }

  /// Sends a [RemoteEvent] to the server and returns a [FlowResult2]
  /// after the event is handled by [Flow].
  Future<FlowResult> dispatchEvent(RemoteEvent event) async {
    logger.fine('dispatching event $event to...');
    analyticsService?.reportMessage(event, DispatchLabels(senderId: _senderId));

    final res = await conn.dispatchEvent(event, const Duration(seconds: 10));

    logger.info('dispatched event $event');

    return res;
  }

  void publishChange(ChangeEnvelop env, {bool save = true}) {
    messageStore.publishChange(env);
  }

  Future<QueryResult> query({
    required String entityId,
    required String name,
    required QueryDef def,
  }) {
    return conn.query(actorId: entityId, name: name, def: def);
  }

  Future<void> subscribeViews(Iterable<ActorViewSub> subs) async {
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
      publishChange(ChangeEnvelop.empty(key: sub.id, name: sub.name));
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

  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs) async {
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
  String? latestStoredChangeIdOf({required String id, required String name}) {
    return messageStore.latestStoredChangeId(id: id, name: name);
  }

  /// Returns a [Stream] of [ChangeEnvelop]s which includes both change history and future changes.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Stream<ChangeEnvelop> changes({
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changes(id: id, name: name, startAt: startAt);
  }

  /// Returns an [Iterable] of [ChangeEnvelop]s from view(or attribute)'s change history,
  /// or an empty [Iterable] if there's no history.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Iterable<ChangeEnvelop> changeHistory({
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changeHistory(id: id, name: name, startAt: startAt);
  }

  /// Returns a [Stream] of [ChangeEnvelop]s which emits future changes which are coming from the server.
  Stream<ChangeEnvelop> futureChanges({
    required String id,
    required String name,
  }) {
    return messageStore.futureChanges(id: id, name: name);
  }

  /// Clears local storage of [Change]s and [RemoteEvent]s.
  void clearStore() {
    messageStore.clear();
  }

  /// Increments the host count for every provided [ActorViewSub] and returns [ActorViewSub]s which should be subscribed.
  Iterable<ActorViewSub> _incViewSubCount(Iterable<ActorViewSub> subs) {
    final viewsToSub = <ActorViewSub>[];

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

  /// Decrements the host count for every provided [ActorViewSub] and returns [ActorViewSub]s which should to be unsubscribed.
  Iterable<ActorViewSub> _decViewSubCount(Iterable<ActorViewSub> subs) {
    final viewsToUnsub = <ActorViewSub>[];

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

/// Test implementation of [HordaClientSystem] for unit testing.
///
/// Provides a no-op implementation that doesn't establish real connections,
/// useful for testing components that depend on the client system.
class TestHordaClientSystem extends HordaClientSystem {
  TestHordaClientSystem({
    super.url = '',
    super.apiKey = '',
    super.authProvider,
  });

  Future<void> start() async {
    // noop
  }

  void stop() {
    // noop
  }
}

/// Provider interface for authentication tokens.
///
/// Implement this interface to provide JWT tokens for authenticated
/// connections to the Horda backend.
///
/// Example:
/// ```dart
/// class MyAuthProvider implements AuthProvider {
///   @override
///   Future<String?> getIdToken() async {
///     return await getCurrentUserJwtToken();
///   }
/// }
/// ```
abstract class AuthProvider {
  Future<String?> getIdToken();
}

/// Service interface for reporting errors to external tracking systems.
///
/// Implement this interface to integrate with error tracking services
/// like Crashlytics, Sentry, or Bugsnag.
abstract class ErrorTrackingService {
  void reportError(Object e, [StackTrace? stack]);
}

/// Service interface for reporting analytics events.
///
/// Implement this interface to integrate with analytics services
/// and track user interactions with the Horda client.
abstract class AnalyticsService {
  void reportMessage(Message msg, [MessageLabels? labels]);
}

/// Base interface for analytics message labels.
///
/// Provides structured metadata for analytics events.
abstract class MessageLabels {
  Map<String, dynamic> toJson();
}

/// Analytics labels for send/call operations.
///
/// Provides metadata about entity commands being sent or called.
@JsonSerializable(createFactory: false)
class SendCallLabels implements MessageLabels {
  SendCallLabels({
    required this.senderId,
    required this.entityId,
    required this.entityName,
  });

  final String senderId;
  final String entityId;
  final String entityName;

  @override
  Map<String, dynamic> toJson() {
    return _$SendCallLabelsToJson(this);
  }
}

/// Analytics labels for event dispatch operations.
///
/// Provides metadata about events being dispatched to the backend.
@JsonSerializable(createFactory: false)
class DispatchLabels implements MessageLabels {
  DispatchLabels({required this.senderId});

  final String senderId;

  @override
  Map<String, dynamic> toJson() {
    return _$DispatchLabelsToJson(this);
  }
}

/// Test implementation of [AuthProvider] for unit testing.
///
/// Returns a static test token, useful for testing scenarios
/// that require authentication without real credentials.
class TestAuthProvider implements AuthProvider {
  Future<String?> getIdToken() {
    return Future.value('test-id-token');
  }
}
