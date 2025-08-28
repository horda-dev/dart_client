import 'dart:async';

import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'actors.dart';
import 'connection.dart';
import 'message.dart';
import 'provider.dart';
import 'system.dart';

typedef FluirFlowLocalHandler<E extends LocalEvent> =
    Future<void> Function(E event, FluirFlowContext context);

abstract class FluirFlowContext {
  Logger get logger;

  FluirAuthState get authState;

  void logout();

  void changeConnection(ConnectionConfig conn);

  void sendLocal(LocalCommand cmd);

  void sendLocalAfter(Duration delay, LocalCommand cmd);

  void sendRemote(String actorName, String actorId, RemoteCommand cmd);

  Future<RemoteEvent> callRemote(
    String actorName,
    String actorId,
    RemoteCommand cmd,
  );

  /// Sends a [RemoteEvent] to the server and returns a [FlowResult2]
  /// after the event is handled by [Flow].
  Future<FlowResult> dispatchEvent(RemoteEvent event);
}

abstract class FluirFlow extends ProxyWidget implements FluirFlowHandlers {
  FluirFlow({super.key, required super.child}) {
    initHandlers(this);
  }

  void initHandlers(FluirFlowHandlers handlers);

  void init(FluirFlowContext context) {}

  void dispose(FluirFlowContext context) {}

  @override
  Element createElement() {
    return FluirFlowElement(this);
  }

  @override
  void addLocal<E extends LocalEvent>(FluirFlowLocalHandler<E> handler) {
    assert(() {
      return !_handlers.containsKey(E);
    }());

    _handlers[E] = handler;
  }

  bool _canHandle(Object event) {
    return _handlers.containsKey(event.runtimeType);
  }

  // event is either Notification or Event subclass
  void _handle(Object event, FluirFlowContext context) async {
    context.logger.fine('handling $event...');
    await _handlers[event.runtimeType](event, context);
    context.logger.info('handled $event');
  }

  final _handlers = <Type, dynamic>{};
}

abstract class FluirFlowHandlers {
  void addLocal<E extends LocalEvent>(FluirFlowLocalHandler<E> handler);
}

class FluirFlowElement extends ProxyElement
    with NotifiableElementMixin
    implements FluirFlowContext {
  FluirFlowElement(super.widget)
    : logger = Logger('Fluir.Flow.${widget.runtimeType}');

  FluirFlow get widget => super.widget as FluirFlow;

  FluirClientSystem get system {
    // FluirSystemProvider.of(this) is still needed because onNotification() can be called
    // before mount(), when the system instance hasn't been assigned yet.
    return _system ?? FluirSystemProvider.of(this);
  }

  // An instance has to be assigned on mount because previously, when FluirSystemProvider.of(this) was called
  // while a FluirFlowElement is being disposed, e.g. through calling context.unsubscribe(),
  // a 'Looking up a deactivated widget's ancestor is unsafe.' exception will be thrown.
  FluirClientSystem? _system;

  @override
  void logout() {
    system.changeAuthState(null);
    system.reopen(
      IncognitoConfig(
        url: system.connectionConfig.url,
        apiKey: system.connectionConfig.apiKey,
      ),
    );
    system.clearStore();
  }

  @override
  void changeConnection(ConnectionConfig conn) {
    if (conn is IncognitoConfig) {
      system.changeAuthState(null);
    }
    system.reopen(conn);
    system.clearStore();
  }

  @override
  FluirAuthState get authState {
    return FluirSystemProvider.authStateOf(this);
  }

  @override
  final Logger logger;

  @override
  void sendLocal(LocalCommand cmd) {
    logger.fine('sending $cmd...');

    system.analyticsService?.reportMessage(cmd);

    var actor = _registeredActors[cmd.runtimeType];
    if (actor != null) {
      actor.handle(cmd);
      logger.info('sent $cmd to ${actor.name}');
      return;
    }

    dispatchNotification(cmd);
    logger.info('sent $cmd up the widget tree');
  }

  @override
  void sendLocalAfter(Duration delay, LocalCommand cmd) {
    Future.delayed(delay, () {
      sendLocal(cmd);
    });
  }

  @override
  void sendRemote(String actorName, String actorId, RemoteCommand cmd) {
    system.sendRemote(actorName, actorId, cmd);
  }

  @override
  Future<RemoteEvent> callRemote(
    String actorName,
    String actorId,
    RemoteCommand cmd,
  ) async {
    try {
      logger.info('calling $actorId with $cmd...');

      var event = await system.callRemote(actorName, actorId, cmd);

      logger.info('received $event from $actorId call');

      return event;
    } on Exception catch (e) {
      var msg = 'received $e from call $cmd to $actorId';
      logger.warning(msg);
      return FluirErrorEvent(msg);
    }
  }

  @override
  Future<FlowResult> dispatchEvent(RemoteEvent event) async {
    try {
      logger.info('dispatching $event...');

      final result = await system.dispatchEvent(event);

      logger.info('received $result from dispatching $event');

      return result;
    } on Exception catch (e) {
      final msg = 'received $e from dispatching $event';

      logger.warning(msg);

      return FlowResult.error(msg);
    }
  }

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _system = FluirSystemProvider.of(this);
    widget.init(this);
    logger.info('element mounted');
  }

  @override
  void unmount() {
    widget.dispose(this);
    super.unmount();
    logger.info('element unmounted');
  }

  @override
  bool onNotification(Notification notification) {
    if (notification is! LocalEvent) {
      return false;
    }

    if (!widget._canHandle(notification)) {
      logger.fine('no handler found for $notification');
      return false;
    }

    widget._handle(notification, this);
    return true;
  }

  @override
  void notifyClients(covariant ProxyWidget oldWidget) {}

  void register(FluirActor actor) {
    for (var type in actor.handleCommands) {
      assert(!_registeredActors.containsKey(type));
      _registeredActors[type] = actor;
    }
  }

  void unregister(FluirActor actor) {
    for (var type in actor.handleCommands) {
      assert(_registeredActors.containsKey(type));
      _registeredActors.remove(type);
    }
  }

  // maps actor's handled command type to actor instance
  final _registeredActors = <Type, FluirActor>{};
}
