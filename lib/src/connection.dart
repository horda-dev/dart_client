import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:async/async.dart';
import 'package:horda_core/horda_core.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/io.dart';

import 'system.dart';

sealed class FluirConnectionState {}

final class ConnectionStateDisconnected implements FluirConnectionState {}

final class ConnectionStateConnecting implements FluirConnectionState {}

final class ConnectionStateConnected implements FluirConnectionState {}

final class ConnectionStateReconnecting implements FluirConnectionState {}

final class ConnectionStateReconnected implements FluirConnectionState {}

sealed class ConnectionConfig {
  ConnectionConfig({
    required this.url,
    required this.apiKey,
  });

  final String url;
  final String apiKey;

  Map<String, dynamic> get httpHeaders => {
        'apiKey': apiKey,
      };
}

class IncognitoConfig extends ConnectionConfig {
  IncognitoConfig({required super.url, required super.apiKey});
}

class LoggedInConfig extends ConnectionConfig {
  LoggedInConfig({required super.url, required super.apiKey});

  @override
  Map<String, dynamic> get httpHeaders => {
        ...super.httpHeaders,
        'isNewUser': false,
      };
}

abstract class Connection implements ValueNotifier<FluirConnectionState> {
  ConnectionConfig get config;

  void open();

  void close();

  void reopen(ConnectionConfig config);

  Future<QueryResult2> query({
    required String actorId,
    required String name,
    required QueryDef def,
  });

  Future<void> send(String actorName, ActorId to, RemoteCommand cmd);

  Future<RemoteEvent> call(
    String actorName,
    ActorId to,
    RemoteCommand cmd,
    Duration timeout,
  );

  Future<FlowResult> dispatchEvent(RemoteEvent event, Duration timeout);

  Future<void> subscribeViews(Iterable<ActorViewSub2> subs);

  Future<void> unsubscribeViews(Iterable<ActorViewSub2> subs);
}

final class WebSocketConnection extends ValueNotifier<FluirConnectionState>
    implements Connection {
  WebSocketConnection(this.system, ConnectionConfig config)
      : logger = Logger('Fluir.Connection'),
        _config = config,
        super(ConnectionStateDisconnected());

  @override
  ConnectionConfig get config => _config;

  final FluirClientSystem system;

  final Logger logger;

  @override
  void open() async {
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

      connected = await _connect();

      retries += 1;
    } while (!connected);

    value = _isFirstTimeConnect
        ? ConnectionStateConnected()
        : ConnectionStateReconnected();

    _isConnected = true;
    _isFirstTimeConnect = false;

    _drainQueue();

    logger.info('opened');
  }

  @override
  void reopen(ConnectionConfig config) {
    close();
    _config = config;
    open();
  }

  @override
  Future<QueryResult2> query({
    required String actorId,
    required String name,
    required QueryDef def,
  }) async {
    var msg = QueryWsMsg2(
      actorId: actorId,
      def: def,
    );

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! QueryResultWsMsg2) {
      logger.severe('query failed with $res');
      throw FluirError(res.toString());
    }

    return res.result;
  }

  @override
  Future<void> send(String actorName, ActorId to, RemoteCommand cmd) async {
    logger.fine('sending $cmd... to $to');

    var msg = SendCommandWsMsg2(actorName, to, cmd);

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! SendCommandAckWsMsg2) {
      logger.severe('send $cmd to $to failed with $res');
      throw FluirError(res.toString());
    }

    logger.info('sent $cmd to $to');
  }

  @override
  Future<RemoteEvent> call(
    String actorName,
    ActorId to,
    RemoteCommand cmd,
    Duration timeout,
  ) async {
    logger.fine('calling $cmd...');

    final msg = CallCommandWsMsg2(actorName, to, cmd);

    final boxId = _send(msg);
    final res = await _boxStream(boxId)
        .map(
          (box) => box.msg,
        )
        .timeout(timeout)
        .first;

    if (res is! CallCommandResWsMsg2) {
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
  Future<FlowResult> dispatchEvent(
    RemoteEvent event,
    Duration timeout,
  ) async {
    logger.fine('dispatching $event...');

    final msg = DispatchEventWsMsg2(event);

    final boxId = _send(msg);
    final res = await _boxStream(boxId)
        .map(
          (box) => box.msg,
        )
        .timeout(timeout)
        .first;

    if (res is! DispatchEventResWsMsg2) {
      logger.severe('dispatch failed with $res');
      throw FluirError(res.toString());
    }

    system.logger.info('dispatched $event');
    return res.result;
  }

  @override
  Future<void> subscribeViews(Iterable<ActorViewSub2> subs) async {
    logger.fine('subscribing to ${subs.toList()} views...');

    final msg = SubscribeViewsWsMsg2(subs.toList());

    final boxId = _send(msg);
    final res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! SubscribeViewsAckWsMsg2) {
      logger.severe('subscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('subscribed to ${subs.toList()} views');
  }

  @override
  Future<void> unsubscribeViews(Iterable<ActorViewSub2> subs) async {
    logger.fine('unsubscribing from ${subs.toList()} views...');

    var msg = UnsubscribeViewsWsMsg2(subs.toList());

    var boxId = _send(msg);
    var res = await _boxStream(boxId).map((box) => box.msg).first;

    if (res is! UnsubscribeViewsResWsMsg2) {
      logger.severe('unsubscribe views resulted in $res');
      throw FluirError(res.toString());
    }

    logger.info('unsubscribed from ${subs.toList()} views');
  }

  Stream<WsMessageBox2> _boxStream(int msgId) {
    return _streamGroup.stream.where((box) => box.id == msgId);
  }

  Future<bool> _connect() async {
    logger.fine('connecting...');

    if (_channel != null) {
      throw FluirError('web socket channel is already opened');
    }

    try {
      final headers = config.httpHeaders;
      headers['idToken'] = await system.authProvider.getIdToken();
      _channel = IOWebSocketChannel.connect(
        config.url,
        headers: headers,
        pingInterval: const Duration(seconds: 5),
        connectTimeout: const Duration(seconds: 5),
      );

      await _channel!.ready;

      _channelStream = _channel!.stream
          .doOnData((data) => logger.fine('received $data'))
          .doOnError(_onStreamError)
          .doOnDone(_onStreamDone)
          .doOnCancel(() => logger.warning('connection got canceled'))
          .map((data) => WsMessageBox2.decodeJson(data, logger));

      _streamGroup.add(_channelStream!);

      _sub = _streamGroup.stream.listen(
        _onStreamData,
      );

      logger.info('connected');

      return true;
    } catch (e, stack) {
      logger.warning('web socket connect exception, url(${config.url}): $e');

      system.errorTrackingService?.reportError(e, stack);

      _close();

      return false;
    }
  }

  int _send(WsMessage2 msg) {
    logger.finer('sending msg $msg...');

    _msgId += 1;
    var box = WsMessageBox2(id: _msgId, msg: msg);

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

  void _sendBox(WsMessageBox2 box) {
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

  void _onStreamData(WsMessageBox2 box) {
    logger.info('received $box');

    final msg = box.msg;

    if (msg is WelcomeWsMsg2) {
      system.changeAuthState(msg.userId);
    }
    if (msg is ViewChangeWsMsg2) {
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

  ConnectionConfig _config;
  IOWebSocketChannel? _channel;
  Stream<WsMessageBox2>? _channelStream;
  StreamSubscription? _sub;
  int _msgId = 0;
  bool _isConnected = false;
  bool _isFirstTimeConnect = true;
  final _streamGroup = StreamGroup<WsMessageBox2>.broadcast();
  final _queue = Queue<WsMessageBox2>();
}
