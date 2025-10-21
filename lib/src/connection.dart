import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:horda_core/horda_core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'system.dart';

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
  /// [name] - Name of the query
  /// [def] - Query definition specifying which views to retrieve
  Future<QueryResult> query({
    required String actorId,
    required String name,
    required QueryDef def,
  });

  /// Sends a command to an entity without waiting for response
  ///
  /// [actorName] - Entity type name
  /// [to] - Target entity ID
  /// [cmd] - Command to send
  Future<void> send(String actorName, EntityId to, RemoteCommand cmd);

  /// Calls a command on an entity and waits for the response
  ///
  /// [actorName] - Entity type name
  /// [to] - Target entity ID
  /// [cmd] - Command to send
  /// [timeout] - Maximum time to wait for response
  Future<RemoteEvent> call(
    String actorName,
    EntityId to,
    RemoteCommand cmd,
    Duration timeout,
  );

  /// Dispatches an event to trigger backend business processes
  ///
  /// [event] - Event to dispatch
  /// [timeout] - Maximum time to wait for completion
  Future<FlowResult> dispatchEvent(RemoteEvent event, Duration timeout);

  /// Subscribes to real-time updates for entity views
  ///
  /// [subs] - View subscriptions to establish
  Future<void> subscribeViews(Iterable<ActorViewSub> subs);

  /// Unsubscribes from real-time updates for entity views
  ///
  /// [subs] - View subscriptions to remove
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs);
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
      super(ConnectionStateDisconnected());

  @override
  String get url => _url;

  @override
  String get apiKey => _apiKey;

  final HordaClientSystem system;

  final Logger logger;

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
        await Future.delayed(delay);
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
  Future<QueryResult> query({
    required String actorId,
    required String name,
    required QueryDef def,
  }) async {
    var msg = QueryWsMsg(actorId: actorId, def: def);

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! QueryResultWsMsg) {
      logger.severe('query failed with $res');
      throw FluirError(res.toString());
    }

    return res.result;
  }

  @override
  Future<void> send(String actorName, EntityId to, RemoteCommand cmd) async {
    logger.fine('sending $cmd... to $to');

    var msg = SendCommandWsMsg(actorName, to, cmd);

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! SendCommandAckWsMsg) {
      logger.severe('send $cmd to $to failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('sent $cmd to $to');
  }

  @override
  Future<RemoteEvent> call(
    String actorName,
    EntityId to,
    RemoteCommand cmd,
    Duration timeout,
  ) async {
    logger.fine('calling $cmd...');

    final msg = CallCommandWsMsg(actorName, to, cmd);

    final boxId = _send(msg);
    final res = await _boxStream(
      boxId,
    ).map((box) => box.msg).timeout(timeout).first;

    if (res is! CallCommandResWsMsg) {
      logger.severe('call failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('called $cmd');

    if (res.isOk) {
      final reply = FlowCallReplyOk.fromJson(res.reply);
      return kMessageFromJson(reply.eventType, reply.event);
    }

    final reply = FlowCallReplyErr.fromJson(res.reply);
    return FluirErrorEvent(reply.message);
  }

  @override
  Future<FlowResult> dispatchEvent(RemoteEvent event, Duration timeout) async {
    logger.fine('dispatching $event...');

    final msg = DispatchEventWsMsg(event);

    final boxId = _send(msg);
    final res = await _boxStream(
      boxId,
    ).map((box) => box.msg).timeout(timeout).first;

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

    final boxId = _send(msg);
    final res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! SubscribeViewsAckWsMsg) {
      logger.severe('subscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('subscribed to ${subs.toList()} views');
  }

  @override
  Future<void> unsubscribeViews(Iterable<ActorViewSub> subs) async {
    logger.fine('unsubscribing from ${subs.toList()} views...');

    var msg = UnsubscribeViewsWsMsg(subs.toList());

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! UnsubscribeViewsResWsMsg) {
      logger.severe('unsubscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('unsubscribed from ${subs.toList()} views');
  }

  Stream<WsMessageBox> _boxStream(int msgId) {
    return _streamGroup.stream.where((box) => box.id == msgId);
  }

  Future<bool> _connect() async {
    logger.fine('connecting...');

    try {
      final headers = <String, String>{
        // API keys are in base64. We have to strip the padding characters to make it a valid subprotocol name.
        // Otherwise we won't be able to send it in the subprotocols header.
        //
        // Server should restore the padding characters for hash matching.
        'apiKey': _apiKey.replaceAll('=', ''),
      };
      final idToken = await system.authProvider?.getFirebaseIdToken();
      if (idToken != null) {
        headers['firebaseIdToken'] = idToken;
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

      _channelStream = newChannel.stream
          .doOnData((data) => logger.fine('received $data'))
          .doOnError(_onStreamError)
          .doOnDone(_onStreamDone)
          .doOnCancel(() => logger.warning('connection got canceled'))
          .map((data) => WsMessageBox.decodeJson(data, logger));
      _streamGroup.add(_channelStream!);
      _sub = _streamGroup.stream.listen(_onStreamData);

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

  int _send(WsMessage msg) {
    logger.finer('sending msg $msg...');

    _msgId += 1;
    var box = WsMessageBox(id: _msgId, msg: msg);

    if (!_isConnected) {
      _queue.addLast(box);
      return _msgId;
    }

    _drainQueue();
    _sendBox(box);

    logger.info('sent msg $msg');

    return _msgId;
  }

  void _drainQueue() {
    assert(_isConnected);
    if (_queue.isEmpty) {
      return;
    }

    logger.fine('draining queue...');

    while (_queue.isNotEmpty) {
      var box = _queue.removeFirst();
      _sendBox(box);
    }

    logger.fine('queue drained');
  }

  void _sendBox(WsMessageBox box) {
    logger.finer('sending box $box..');

    var data = box.encodeJson(logger);

    _channel!.sink.add(data);

    logger.fine('sent box $box');
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
    logger.fine('closing channel...');

    _sub?.cancel();
    if (_channelStream != null) {
      _streamGroup.remove(_channelStream!);
    }
    _channel?.sink.close();
    _channel = null;
    _channelStream = null;
    _sub = null;
    _isConnected = false;

    logger.info('channel closed');
  }

  void _onStreamData(WsMessageBox box) {
    logger.info('received $box');

    final msg = box.msg;

    if (msg is WelcomeWsMsg) {
      system.changeAuthState(msg.userId);
    }
    if (msg is ViewChangeWsMsg) {
      system.publishChange(msg.env);
    }
  }

  void _onStreamError(Object error, StackTrace stack) {
    logger.warning('got error: $error');

    Future.delayed(Duration.zero, () => open());
  }

  void _onStreamDone() {
    logger.warning(
      'closed with code: ${_channel?.closeCode} reason ${_channel?.closeReason}',
    );

    if (value is ConnectionStateDisconnected) {
      // Don't try to reconnect when close() was called.
      return;
    }

    Future.delayed(Duration.zero, () => open());
  }

  String _url;
  String _apiKey;
  WebSocketChannel? _channel;
  Stream<WsMessageBox>? _channelStream;
  StreamSubscription? _sub;
  int _msgId = 0;
  bool _isConnected = false;
  bool _isFirstTimeConnect = true;
  final _streamGroup = StreamGroup<WsMessageBox>.broadcast();
  final _queue = Queue<WsMessageBox>();
}

class ConnectionException implements Exception {
  ConnectionException(this.message);

  final String message;

  @override
  String toString() {
    return message;
  }
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
