import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:horda_core/horda_core.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'system.dart';

part 'connection.g.dart';

/// Represents the current state of the WebSocket connection to the Horda backend.
///
/// The SDK automatically manages connection states and handles reconnection
/// in case of lost connectivity. Use `context.hordaConnectionState` to access
/// the current connection state in your widgets.
sealed class HordaConnectionState {}

/// Connection is closed and not attempting to reconnect.
///
/// This state occurs when the connection is manually closed or when
/// the initial connection attempt has not yet been made.
final class ConnectionStateDisconnected implements HordaConnectionState {}

/// Initial connection attempt is in progress.
///
/// This is the first connection attempt when the system starts up.
final class ConnectionStateConnecting implements HordaConnectionState {}

/// Successfully connected to the Horda backend.
///
/// The WebSocket connection is established and ready to send/receive data.
final class ConnectionStateConnected implements HordaConnectionState {}

/// Attempting to reconnect after a connection loss.
///
/// The connection was previously established but was lost due to network
/// issues or server problems. The SDK is attempting to reconnect.
final class ConnectionStateReconnecting implements HordaConnectionState {}

/// Successfully reconnected after a connection loss.
///
/// The connection has been restored and is ready to resume normal operation.
final class ConnectionStateReconnected implements HordaConnectionState {}

/// Abstract interface for managing WebSocket connections to the Horda backend.
///
/// Handles all communication with the server including queries, commands, events,
/// and view subscriptions. The connection automatically manages reconnection and
/// provides real-time updates through WebSocket.
abstract class Connection implements ValueNotifier<HordaConnectionState> {
  /// WebSocket URL for the Horda backend in format: wss://api.horda.ai/[PROJECT_ID]/client
  String get url;

  /// API key for your Horda project
  String get apiKey;

  /// Opens the WebSocket connection to the backend
  Future<void> open();

  /// Closes the WebSocket connection
  void close();

  /// Reopens the connection with a new configuration
  Future<void> reopen();

  /// Executes a query against an entity's views
  ///
  /// [actorId] - ID of the entity to query
  /// [def] - Query definition specifying which views to retrieve
  Future<QueryResult> query({
    required String actorId,
    required QueryDef def,
  });

  /// Executes an atomic query and subscribe operation
  ///
  /// Combines query execution and view subscription into a single atomic operation,
  /// preventing race conditions between query result and subscription start.
  ///
  /// [actorId] - ID of the entity to query
  /// [def] - Query definition specifying which views to retrieve
  /// [subs] - View subscriptions to establish
  Future<QueryResult> queryAndSubscribe({
    required String actorId,
    required QueryDef def,
  });

  /// Sends a command to an entity without waiting for response
  ///
  /// [actorName] - Entity type name
  /// [to] - Target entity ID
  /// [cmd] - Command to send
  Future<void> sendEntity(String actorName, EntityId to, RemoteCommand cmd);

  /// Calls a command on an entity and waits for the response
  ///
  /// [actorName] - Entity type name
  /// [to] - Target entity ID
  /// [cmd] - Command to send
  /// [timeout] - Maximum time to wait for response
  Future<E> callEntity<E extends RemoteEvent>(
    String actorName,
    EntityId to,
    RemoteCommand cmd,
    FromJsonFun<E> fac,
    Duration timeout,
  );

  /// Dispatches an event to trigger backend business processes
  ///
  /// [event] - Event to dispatch
  /// [timeout] - Maximum time to wait for completion
  Future<ProcessResult> runProcess(RemoteEvent event, Duration timeout);

  /// Subscribes to real-time updates for entity views
  ///
  /// [subs] - View subscriptions to establish
  Future<void> subscribeViews(Iterable<ActorViewSub> subs);

  /// Unsubscribes from real-time updates for entity views
  ///
  /// [subs] - View subscriptions to remove
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs);

  /// Resets the reconnection backoff and wakes any pending reconnect delay.
  /// No-op when the connection is healthy, idle, or intentionally closed.
  ///
  /// Should be called when the app returned to the foreground.
  void resetReconnectBackoff();
}

/// WebSocket implementation of the [Connection] interface.
///
/// Manages the actual WebSocket connection to the Horda backend with features like:
/// - Automatic reconnection with exponential backoff
/// - Message queuing during disconnection
/// - Real-time communication for queries, commands, and events
/// - View subscription management for live data updates
final class WebSocketConnection extends ValueNotifier<HordaConnectionState>
    implements Connection {
  WebSocketConnection(this.system, this._url, this._apiKey)
    : logger = Logger('Fluir.Connection'),
      super(ConnectionStateDisconnected()) {
    addListener(
      () => system.errorTrackingService?.reportConnectionState(value),
    );
  }

  @override
  String get url => _url;

  @override
  String get apiKey => _apiKey;

  final HordaClientSystem system;

  final Logger logger;

  /// Default timeout for socket requests whose duration isn't caller-specified.
  static const _defaultRequestTimeout = Duration(seconds: 10);

  static const _clientCloseReason = 'Client closed connection';

  @override
  Future<void> open() async {
    logger.fine('opening...');
    _isConnected = false;

    if (_channel != null) {
      _close();
    }

    value = _isFirstTimeConnect
        ? ConnectionStateConnecting()
        : ConnectionStateReconnecting();

    var maxDelay = const Duration(seconds: 30);
    var retries = 0;
    var connected = false;

    do {
      if (value is ConnectionStateDisconnected) {
        // Break the reconnection loop, because close() was called.
        return;
      }

      // After 5 retries, simply use maxDelay.
      // Otherwise int overflow on try 55 will cause an absurdly large delay.
      // Ref: https://gitlab.com/horda/delurk/script/-/issues/12
      final delay = retries > 5
          ? maxDelay
          : Duration(
              milliseconds: min(
                pow(2, retries).toInt() * 1000,
                maxDelay.inMilliseconds,
              ),
            );

      if (retries != 0) {
        logger.fine('reconnecting after ${delay.inSeconds} seconds...');

        final wake = Completer<void>();
        _backoffWake = wake;
        var interrupted = false;

        await Future.any([
          Future.delayed(delay),
          wake.future.then((_) => interrupted = true),
        ]);

        // Only clear the field if it still refers to our completer; a
        // concurrent open() may have installed a newer one.
        if (identical(_backoffWake, wake)) {
          _backoffWake = null;
        }

        if (interrupted) {
          // The backoff was reset when app was foregrounded.
          retries = 0;
        }
      }

      // close() may have run while we were delayed; honor it before
      // attempting another connection.
      if (value is ConnectionStateDisconnected) {
        return;
      }

      try {
        connected = await _connect();
      } on ChannelDisposedWhileWaitingException {
        // A new websocket connection (another async open() call) is being opened
        // while waiting for the previous one. Stop execution to avoid mutating state.
        return;
      }

      retries += 1;
    } while (!connected);

    value = _isFirstTimeConnect
        ? ConnectionStateConnected()
        : ConnectionStateReconnected();

    _isConnected = true;
    _isFirstTimeConnect = false;

    _drainQueue();

    logger.fine('opened');
  }

  @override
  Future<void> reopen() async {
    close();
    await open();
  }

  @override
  void resetReconnectBackoff() {
    final wake = _backoffWake;
    if (wake != null && !wake.isCompleted) {
      logger.fine('resetting reconnect backoff');
      wake.complete();
    }
  }

  @override
  Future<QueryResult> query({
    required String actorId,
    required QueryDef def,
  }) async {
    final msg = QueryWsMsg(actorId: actorId, def: def);

    final res = await _send(msg, timeout: _defaultRequestTimeout);

    if (res is! QueryResultWsMsg) {
      logger.severe('query failed with $res');
      throw FluirError(res.toString());
    }

    return res.result;
  }

  @override
  Future<QueryResult> queryAndSubscribe({
    required String actorId,
    required QueryDef def,
  }) async {
    logger.fine('$actorId: atomic query and subscribe...');

    final msg = QueryAndSubscribeWsMsg(
      actorId: actorId,
      def: def,
    );

    final res = await _send(msg, timeout: _defaultRequestTimeout);

    if (res is! QueryResultWsMsg) {
      logger.severe('query and subscribe failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('$actorId: atomic query and subscribe completed');

    return res.result;
  }

  @override
  Future<void> sendEntity(
    String entityName,
    EntityId to,
    RemoteCommand cmd,
  ) async {
    logger.fine('sending $cmd... to $to');

    final msg = SendCommandWsMsg(entityName, to, cmd);
    final res = await _send(msg, timeout: _defaultRequestTimeout);

    if (res is! SendCommandAckWsMsg) {
      logger.severe('send $cmd to $to failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('sent $cmd to $to');
  }

  @override
  Future<E> callEntity<E extends RemoteEvent>(
    String entityName,
    EntityId to,
    RemoteCommand cmd,
    FromJsonFun<E> fac,
    Duration timeout,
  ) async {
    logger.fine('calling $cmd...');

    final msg = CallCommandWsMsg(entityName, to, cmd);

    final res = await _send(msg, timeout: timeout);

    if (res is! CallCommandResWsMsg) {
      logger.severe('call failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('called $cmd');

    if (res.isOk) {
      final reply = FlowCallReplyOk.fromJson(res.reply);

      if (reply.eventType != E.toString()) {
        throw FluirError(
          'call received unexpected event type: ${reply.eventType}',
        );
      }

      return fac(reply.event);
    }

    final reply = FlowCallReplyErr.fromJson(res.reply);

    throw FluirError(reply.message);
  }

  @override
  Future<ProcessResult> runProcess(
    RemoteEvent event,
    Duration timeout,
  ) async {
    logger.fine('dispatching $event...');

    final msg = DispatchEventWsMsg(event);

    final res = await _send(msg, timeout: timeout);

    if (res is! DispatchEventResWsMsg) {
      logger.severe('dispatch failed with $res');
      throw FluirError(res.toString());
    }

    system.logger.info('dispatched $event');
    return res.result;
  }

  @override
  Future<void> subscribeViews(Iterable<ActorViewSub> subs) async {
    logger.fine('subscribing to ${subs.toList()} views...');

    final msg = SubscribeViewsWsMsg(subs.toList());

    final res = await _send(msg, timeout: _defaultRequestTimeout);

    if (res is! SubscribeViewsAckWsMsg) {
      logger.severe('subscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('subscribed to ${subs.toList()} views');
  }

  @override
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs) async {
    logger.fine('unsubscribing from ${subs.toList()} views...');

    final msg = UnsubscribeViewsWsMsg(subs.toList());

    final res = await _send(msg, timeout: _defaultRequestTimeout);

    if (res is! UnsubscribeViewsResWsMsg) {
      logger.severe('unsubscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('unsubscribed from ${subs.toList()} views');
  }

  Future<bool> _connect() async {
    logger.fine('connecting...');

    try {
      final headers = <String, String>{
        'apiKey': _apiKey,
      };

      final authEvent = await system.authProvider?.getAuthEvent();
      if (authEvent != null) {
        final jsonString = jsonEncode(
          AuthenticationEvent(authEvent),
        );
        // Dart's base64UrlEncode includes padding characters, so remove it manually.
        final base64String = base64UrlEncode(
          utf8.encode(jsonString),
        ).replaceAll('=', '');
        headers['authEvent'] = base64String;
      }

      // Must check if channel is already assigned exactly before assigning a new channel.
      // Otherwise multiple async calls to _connect() can overwrite the _channel and conflict
      // with each other, causing unexpected behavior.
      //
      // In this case such issue can occur due to the async gap when getting the id token, in the code above.
      if (_channel != null) {
        throw ChannelOverwriteException();
      }

      final newChannel = WebSocketChannel.connect(
        Uri.parse(_url),
        protocols: [
          // WebSocket server expects "horda" subprotocol and will respond with it as the negotiated subprotocol.
          // If we don't request at least one matching subprotocol name, the client will close connection.
          // Other subrotocol entries are actually headers: api key, firebase id token, etc.
          'horda',
          for (final headerValue in headers.values) headerValue,
        ],
      );
      _channel = newChannel;

      await newChannel.ready;

      // If this is true, it means that _close() was called and the 'newChannel' was disposed
      // while we were waiting for it to open.
      if (newChannel != _channel) {
        throw ChannelDisposedWhileWaitingException();
      }

      _sub = newChannel.stream.listen(
        (data) {
          logger.fine('received $data');
          _onStreamData(WsMessageBox.decodeJson(data, logger));
        },
        onError: (Object error, StackTrace stackTrace) {
          _onStreamError(newChannel, error, stackTrace);
        },
        onDone: () => _onStreamDone(newChannel),
      );

      logger.info('connected');

      return true;
    } on ChannelDisposedWhileWaitingException {
      // Expected behavior, happens when connection is being reopened in a quick succession.
      logger.fine(
        'previous web socket channel was disposed while waiting for it to open',
      );

      rethrow;
    } catch (e, stack) {
      logger.warning('web socket connect exception, url($_url): $e');

      system.errorTrackingService?.reportError(e, stack);

      _close();

      return false;
    }
  }

  Future<WsMessage> _send(
    WsMessage msg, {
    Duration? timeout,
  }) {
    logger.finer('sending msg $msg...');

    _msgId += 1;
    final request = _PendingRequest(
      WsMessageBox(id: _msgId, msg: msg),
    );

    if (!_isConnected) {
      _queue.addLast(request);
      return _awaitResponse(request, timeout: timeout);
    }

    _drainQueue();
    _sendRequest(request);

    logger.info('sent msg $msg');

    return _awaitResponse(request, timeout: timeout);
  }

  Future<WsMessage> _awaitResponse(
    _PendingRequest request, {
    Duration? timeout,
  }) {
    if (timeout == null) {
      return request.completer.future;
    }

    return request.completer.future.timeout(
      timeout,
      onTimeout: () {
        _removeRequest(request);
        throw TimeoutException('request ${request.box.id} timed out', timeout);
      },
    );
  }

  void _removeRequest(_PendingRequest request) {
    _pending.remove(request.box.id);
    _queue.remove(request);
  }

  void _drainQueue() {
    assert(_isConnected);
    if (_queue.isEmpty) {
      return;
    }

    logger.fine('draining queue...');

    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      _sendRequest(request);
    }

    logger.fine('queue drained');
  }

  void _sendRequest(_PendingRequest request) {
    final channel = _channel;
    if (channel == null) {
      request.completer.completeError(
        ConnectionException('attempted to send without an active connection'),
      );
      return;
    }

    request.channel = channel;
    _pending[request.box.id] = request;

    logger.finer('sending box ${request.box}..');

    final data = request.box.encodeJson(logger);

    try {
      channel.sink.add(data);
    } catch (error, stackTrace) {
      _pending.remove(request.box.id);
      request.completer.completeError(error, stackTrace);
      return;
    }

    logger.fine('sent box ${request.box}');
    logger.fine('sent data $data');
  }

  @override
  void close() {
    _close();

    // Assign disconnected state here, because calling public close() method
    // means that we don't intend to try reconnecting further.
    value = ConnectionStateDisconnected();
  }

  void _close() {
    final channel = _channel;
    if (channel != null) {
      logger.info(
        'closing channel with code=${ws_status.normalClosure} '
        'reason=$_clientCloseReason',
      );

      // GKE's load balancer can surface a trailing 1006 after this local teardown.
      // We intentionally ignore it.
      system.errorTrackingService?.reportConnectionClosure(
        ws_status.normalClosure,
        _clientCloseReason,
      );

      _failRequestsForChannel(
        channel,
        StackTrace.current,
      );

      _sub?.cancel();
      channel.sink.close(
        ws_status.normalClosure,
        _clientCloseReason,
      );
    }

    _channel = null;
    _sub = null;
    _isConnected = false;

    logger.info('channel closed');
  }

  void _onStreamData(WsMessageBox box) {
    logger.info('received $box');

    final request = _pending.remove(box.id);
    if (request != null) {
      request.completer.complete(box.msg);
      return;
    }

    final msg = box.msg;

    if (msg is WelcomeWsMsg) {
      system.changeAuthState(msg.userId);
    }
    if (msg is ViewChangeWsMsg) {
      system.publishChange(msg.env);
    }
  }

  void _onStreamError(
    WebSocketChannel channel,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_channel, channel)) {
      return;
    }

    logger.warning('got error: $error');

    _isConnected = false;

    _failRequestsForChannel(
      channel,
      stackTrace,
    );

    _scheduleReconnect();
  }

  void _onStreamDone(WebSocketChannel channel) {
    if (!identical(_channel, channel)) {
      return;
    }

    logger.warning(
      'closed with code: ${channel.closeCode} reason ${channel.closeReason}',
    );

    system.errorTrackingService?.reportConnectionClosure(
      channel.closeCode,
      channel.closeReason,
    );

    _isConnected = false;

    _failRequestsForChannel(
      channel,
      StackTrace.current,
    );

    _channel = null;
    _sub = null;

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    Future.delayed(Duration.zero, () {
      if (value is ConnectionStateDisconnected) {
        // Don't try to reconnect when close() was called.
        return;
      }

      open();
    });
  }

  void _failRequestsForChannel(
    WebSocketChannel channel,
    StackTrace stackTrace,
  ) {
    final error = ConnectionClosedException();
    final requests = _pending.values
        .where((request) => identical(request.channel, channel))
        .toList();

    if (requests.isNotEmpty) {
      logger.warning(
        'failing ${requests.length} pending request(s): $error',
      );
    }

    for (final request in requests) {
      _pending.remove(request.box.id);
      request.completer.completeError(error, stackTrace);
    }
  }

  String _url;
  String _apiKey;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  int _msgId = 0;
  bool _isConnected = false;
  bool _isFirstTimeConnect = true;
  Completer<void>? _backoffWake;
  final _pending = <int, _PendingRequest>{};
  final _queue = Queue<_PendingRequest>();
}

class ConnectionException implements Exception {
  ConnectionException(this.message);

  final String message;

  @override
  String toString() {
    return message;
  }
}

/// The WebSocket connection closed before a sent request received a response.
class ConnectionClosedException extends ConnectionException {
  ConnectionClosedException() : super('web socket connection closed');
}

class _PendingRequest {
  _PendingRequest(this.box);

  final WsMessageBox box;
  final completer = Completer<WsMessage>();
  WebSocketChannel? channel;
}

/// This exception may occur if a new websocket channel
/// is being opened without cleaning up the existing one.
class ChannelOverwriteException extends ConnectionException {
  ChannelOverwriteException()
    : super('attempted to overwrite the web socket channel');
}

/// Expected exception, thrown if a new websocket connections was opened
/// while we were waiting for the previous one to open.
///
/// This exception should be used to prevent the two async calls to [Connection.open]
/// from conflicting with each other, mutating shared state, causing other unexpected behaviour.
class ChannelDisposedWhileWaitingException extends ConnectionException {
  ChannelDisposedWhileWaitingException()
    : super('web socket channel was disposed while waiting for it to open');
}

@JsonSerializable(createFactory: false)
class AuthenticationEvent {
  AuthenticationEvent(RemoteEvent event)
    : eventType = event.runtimeType.toString(),
      payload = event;

  final String eventType;
  final RemoteEvent payload;

  Map<String, dynamic> toJson() {
    return _$AuthenticationEventToJson(this);
  }
}
