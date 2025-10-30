import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:horda_core/horda_core.dart';
import 'package:logging/logging.dart';

import 'entities.dart';
import 'message.dart';
import 'provider.dart';
import 'system.dart';

typedef HordaProcessLocalHandler<E extends LocalEvent> =
    Future<void> Function(E event, HordaProcessContext context);

abstract class HordaProcessContext {
  Logger get logger;

  HordaAuthState get authState;

  void logout();

  void changeConnection();

  void sendLocal(LocalCommand cmd);

  void sendLocalAfter(Duration delay, LocalCommand cmd);

  void sendEntity({
    required String name,
    required String id,
    required RemoteCommand cmd,
  });

  Future<E> callEntity<E extends RemoteEvent>({
    required String name,
    required String id,
    required RemoteCommand cmd,
    required FromJsonFun<E> fac,
  });

  /// Sends a [RemoteEvent] to the server and returns a [ProcessResult]
  /// after the event is handled by [Flow].
  Future<ProcessResult> dispatchEvent(RemoteEvent event);
}

abstract class HordaProcess extends ProxyWidget
    implements HordaProcessHandlers {
  HordaProcess({super.key, required super.child}) {
    initHandlers(this);
  }

  void initHandlers(HordaProcessHandlers handlers);

  void init(HordaProcessContext context) {}

  void dispose(HordaProcessContext context) {}

  @override
  Element createElement() {
    return HordaProcessElement(this);
  }

  @override
  void addLocal<E extends LocalEvent>(HordaProcessLocalHandler<E> handler) {
    assert(() {
      return !_handlers.containsKey(E);
    }());

    _handlers[E] = handler;
  }

  bool _canHandle(Object event) {
    return _handlers.containsKey(event.runtimeType);
  }

  // event is either Notification or Event subclass
  void _handle(Object event, HordaProcessContext context) async {
    context.logger.fine('handling $event...');
    await _handlers[event.runtimeType](event, context);
    context.logger.info('handled $event');
  }

  final _handlers = <Type, dynamic>{};
}

abstract class HordaProcessHandlers {
  void addLocal<E extends LocalEvent>(HordaProcessLocalHandler<E> handler);
}

class HordaProcessElement extends ProxyElement
    with NotifiableElementMixin
    implements HordaProcessContext {
  HordaProcessElement(super.widget)
    : logger = Logger('Fluir.Flow.${widget.runtimeType}');

  HordaProcess get widget => super.widget as HordaProcess;

  HordaClientSystem get system {
    // FluirSystemProvider.of(this) is still needed because onNotification() can be called
    // before mount(), when the system instance hasn't been assigned yet.
    return _system ?? HordaSystemProvider.of(this);
  }

  // An instance has to be assigned on mount because previously, when FluirSystemProvider.of(this) was called
  // while a FluirFlowElement is being disposed, e.g. through calling context.unsubscribe(),
  // a 'Looking up a deactivated widget's ancestor is unsafe.' exception will be thrown.
  HordaClientSystem? _system;

  @override
  Future<void> logout() async {
    system.changeAuthState(null);
    system.clearStore();
    await system.reopen();
  }

  @override
  void changeConnection() {
    // If authProvider is null, it means we are in incognito mode.
    // So, when changing connection, if the new connection is incognito, we should change auth state to incognito.
    if (system.authProvider == null) {
      system.changeAuthState(null);
    }
    system.reopen();
    system.clearStore();
  }

  @override
  HordaAuthState get authState {
    return HordaSystemProvider.authStateOf(this);
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
  void sendEntity({
    required String name,
    required String id,
    required RemoteCommand cmd,
  }) {
    system.sendEntity(
      name: name,
      id: id,
      cmd: cmd,
    );
  }

  @override
  Future<E> callEntity<E extends RemoteEvent>({
    required String name,
    required String id,
    required RemoteCommand cmd,
    required FromJsonFun<E> fac,
  }) async {
    logger.info('calling $id with $cmd...');

    final event = await system.callEntity(
      name: name,
      id: id,
      cmd: cmd,
      fac: fac,
    );

    logger.info('received $event from $id call');

    return event;
  }

  @override
  Future<ProcessResult> dispatchEvent(RemoteEvent event) async {
    try {
      logger.info('dispatching $event...');

      final result = await system.dispatchEvent(event);

      logger.info('received $result from dispatching $event');

      return result;
    } on Exception catch (e) {
      final msg = 'received $e from dispatching $event';

      logger.warning(msg);

      return ProcessResult.error(msg);
    }
  }

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _system = HordaSystemProvider.of(this);
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

  void register(HordaEntity actor) {
    for (var type in actor.handleCommands) {
      assert(!_registeredActors.containsKey(type));
      _registeredActors[type] = actor;
    }
  }

  void unregister(HordaEntity actor) {
    for (var type in actor.handleCommands) {
      assert(_registeredActors.containsKey(type));
      _registeredActors.remove(type);
    }
  }

  // maps actor's handled command type to actor instance
  final _registeredActors = <Type, HordaEntity>{};
}
