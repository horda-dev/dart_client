import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:horda_core/horda_core.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'message_store.dart';
import 'provider.dart';
import 'query.dart';
import 'query_synchronizer.dart';

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

  HordaClientSystem._withConnection({
    required this.conn,
    this.authProvider,
    this.analyticsService,
    this.errorTrackingService,
  }) : authState = ValueNotifier<HordaAuthState>(
         authProvider == null ? AuthStateIncognito() : AuthStateValidating(),
       ) {
    logger = Logger('Fluir.System');
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

  void sendEntity({
    required String name,
    required EntityId id,
    required RemoteCommand cmd,
  }) {
    logger.fine('sending remote command $cmd to $id...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        entityId: id,
        entityName: name,
      ),
    );

    try {
      conn.sendEntity(name, id, cmd);
    } catch (e) {
      logger.severe('send remote $cmd to $id failed with $e');
      return;
    }

    logger.info('sent remote $cmd to $id');
  }

  Future<E> callEntity<E extends RemoteEvent>({
    required String name,
    required EntityId id,
    required RemoteCommand cmd,
    required FromJsonFun<E> fac,
  }) async {
    logger.fine('calling remote command $cmd to $id...');
    analyticsService?.reportMessage(
      cmd,
      SendCallLabels(
        senderId: _senderId,
        entityId: id,
        entityName: name,
      ),
    );

    final res = await conn.callEntity(
      name,
      id,
      cmd,
      fac,
      const Duration(seconds: 10),
    );

    logger.info('called command $cmd to $id');

    return res;
  }

  /// Sends a [RemoteEvent] to the server and returns a [ProcessResult]
  /// after the event is handled by [Flow].
  Future<ProcessResult> runProcess(RemoteEvent event) async {
    logger.fine('dispatching event $event to...');
    analyticsService?.reportMessage(event, DispatchLabels(senderId: _senderId));

    final res = await conn.runProcess(event, const Duration(seconds: 10));

    logger.info('dispatched event $event');

    return res;
  }

  void publishChange(ChangeEnvelop env, {bool save = true}) {
    messageStore.publishChange(env);
  }

  /// Finalizes query subscriptions after atomic query+subscribe completes.
  ///
  /// This method:
  /// 1. Increments reference counts for all provided subscriptions
  /// 2. Publishes empty change envelopes for views that were already subscribed by other hosts
  /// 3. Marks the in-flight query as complete, allowing waiting unsubscribe operations to proceed
  ///
  /// Unlike [subscribeViews], this does NOT call the server since the subscriptions
  /// were already created atomically during the query operation.
  ///
  /// This should be called AFTER [ActorViewHost.attach], when [ActorViewHost] has set up change stream listeners.
  ///
  /// [queryKey] - Query identifier in format "entityId/queryName"
  /// [subs] - Subscriptions collected from [ActorQueryHost] after attach
  void finalizeQuerySubscriptions(
    String queryKey,
    Iterable<ActorViewSub> subs,
  ) {
    final readyToSub = _incViewSubCount(subs);
    final alreadySubscribed = subs.toSet().difference(readyToSub.toSet());

    for (final sub in alreadySubscribed) {
      logger.info(
        'View $sub was already subscribed, publishing empty change envelope',
      );
      publishChange(
        ChangeEnvelop.empty(
          entityName: sub.entityName,
          key: sub.id,
          name: sub.name,
        ),
      );
    }

    // Mark query tracking as complete
    _querySynchronizer.completeQuery(queryKey);
  }

  Future<QueryResult> query({
    required String entityId,
    required QueryDef def,
  }) {
    return conn.query(actorId: entityId, def: def);
  }

  Future<QueryResult> queryAndSubscribe({
    required String queryKey,
    required String entityId,
    required QueryDef def,
  }) async {
    logger.fine('$entityId: atomic query and subscribe...');

    // Register in-flight query
    final completer = _querySynchronizer.registerQuery(queryKey);

    try {
      final result = await conn.queryAndSubscribe(
        actorId: entityId,
        def: def,
      );

      logger.info('$entityId: atomic query and subscribe completed');
      return result;
    } catch (e) {
      logger.severe('query and subscribe error $e');
      rethrow;
    } finally {
      // Note: completer is completed in finalizeQuerySubscriptions()
      // We only clean up here if the query failed before finalization
      _querySynchronizer.cleanupQuery(queryKey, completer);
    }
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
      publishChange(
        ChangeEnvelop.empty(
          entityName: sub.entityName,
          key: sub.id,
          name: sub.name,
        ),
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

  Future<void> unsubscribeViews(
    String queryKey,
    Iterable<ActorViewSub> subs,
  ) async {
    // Wait for an identical in-flight query to finish, if one exists
    await _querySynchronizer.waitForQuery(queryKey);

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
    required String entityName,
    required String id,
    required String name,
  }) {
    return messageStore.latestStoredChangeId(
      entityName: entityName,
      id: id,
      name: name,
    );
  }

  /// Returns a [Stream] of [ChangeEnvelop]s which includes both change history and future changes.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Stream<ChangeEnvelop> changes({
    required String entityName,
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changes(
      entityName: entityName,
      id: id,
      name: name,
      startAt: startAt,
    );
  }

  /// Returns an [Iterable] of [ChangeEnvelop]s from view(or attribute)'s change history,
  /// or an empty [Iterable] if there's no history.
  ///
  /// [startAt] is a change id which we want to start getting changes at from history.
  Iterable<ChangeEnvelop> changeHistory({
    required String entityName,
    required String id,
    required String name,
    String startAt = '',
  }) {
    return messageStore.changeHistory(
      entityName: entityName,
      id: id,
      name: name,
      startAt: startAt,
    );
  }

  /// Returns a [Stream] of [ChangeEnvelop]s which emits future changes which are coming from the server.
  Stream<ChangeEnvelop> futureChanges({
    required String entityName,
    required String id,
    required String name,
  }) {
    return messageStore.futureChanges(
      entityName: entityName,
      id: id,
      name: name,
    );
  }

  /// Clears local storage of [Change]s and [RemoteEvent]s.
  void clearStore() {
    messageStore.clear();
  }

  /// Increments the host count for every provided [ActorViewSub] and returns [ActorViewSub]s which should be subscribed.
  Iterable<ActorViewSub> _incViewSubCount(Iterable<ActorViewSub> subs) {
    final viewsToSub = <ActorViewSub>[];

    for (final sub in subs) {
      final subKey = sub.subKey;

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
      final subKey = sub.subKey;

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
  /// - Key - view subscription key:
  ///   - For regular views: entityName/id/name
  ///   - For list views: entityName/id/name:pageId (each list view is tracked separately, because pageId is unique)
  ///   - For attributes: id/name
  /// - Value - count of hosts which depend on a view subscription
  final _viewSubCount = <String, int>{};

  /// TODO: Remove when QuerySynchronizer is no longer needed
  /// Temporary fix for queryAndSubscribe/unsubscribe desync during widget element substitution
  final _querySynchronizer = QuerySynchronizer();
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

  TestHordaClientSystem.withConnection({
    required super.conn,
  }) : super._withConnection();

  /// Exposes the view subscription count map for testing purposes.
  ///
  /// Returns an unmodifiable map to prevent external modification while
  /// allowing tests to verify reference counting behavior.
  Map<String, int> get viewSubCount => Map.unmodifiable(_viewSubCount);

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
///   Future<String?> getFirebaseIdToken() async {
///     return await getCurrentUserJwtToken();
///   }
/// }
/// ```
abstract class AuthProvider {
  Future<String?> getFirebaseIdToken();
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
  Future<String?> getFirebaseIdToken() {
    return Future.value('test-id-token');
  }
}
