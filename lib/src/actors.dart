import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'flow.dart';
import 'message.dart';
import 'provider.dart';
import 'system.dart';

typedef FluirActorHandler<C extends LocalCommand> = Future<void> Function(
  C cmd,
  FluirActorContext context,
);

abstract class FluirActorContext {
  Logger get logger;
}

class FluirActor {
  FluirActor({
    required this.name,
    required this.context,
  });

  final String name;

  final FluirActorContext context;

  Iterable<Type> get handleCommands => _handlers.keys;

  void addHandler<C extends LocalCommand>(FluirActorHandler<C> handler) {
    assert(!_handlers.containsKey(C));

    _handlers[C] = handler;
  }

  bool canHandle(LocalCommand cmd) {
    return _handlers.containsKey(cmd.runtimeType);
  }

  void handle(LocalCommand cmd) {
    context.logger.fine('handling $cmd...');

    if (!canHandle(cmd)) {
      context.logger.warning('no handler registered for ${cmd.runtimeType}');
      return;
    }

    if (!_idle) {
      _inbox.add(cmd);
      context.logger.info('added $cmd to inbox');
      return;
    }

    _loop(cmd);
  }

  void stop() {
    context.logger.fine('stopping...');
    _inbox.clear();
    context.logger.info('stopped');
  }

  void _loop(LocalCommand cmd) async {
    _idle = false;
    _inbox.add(cmd);

    do {
      final next = _inbox.removeFirst();

      try {
        context.logger.fine('loop handling $next...');

        await _handlers[next.runtimeType](next, context);

        context.logger.info('loop handled $next');
      } catch (e) {
        context.logger.severe('loop handled $next with error: $e');
      }
    } while (_inbox.isNotEmpty);
    _idle = true;
  }

  final _handlers = <Type, dynamic>{};
  final _inbox = Queue<LocalCommand>();
  var _idle = true;
}

abstract class FluirActorHandlers {
  void add<C extends LocalCommand>(FluirActorHandler<C> handler);
}

abstract class ProxyActor extends ProxyWidget {
  ProxyActor({super.key, required super.child});

  void initHandlers(FluirActorHandlers handlers);

  @override
  Element createElement() {
    return _ProxyActorElement(this);
  }
}

class _ProxyActorElement extends ProxyElement
    with NotifiableElementMixin
    implements FluirActorContext, FluirActorHandlers {
  _ProxyActorElement(super.widget)
      : logger = Logger('Fluir.Actor.${widget.runtimeType}') {
    _actor = FluirActor(name: widget.runtimeType.toString(), context: this);
  }

  @override
  final Logger logger;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);

    (widget as ProxyActor).initHandlers(this);
    logger.fine('element mounted');
  }

  @override
  void unmount() {
    _actor.stop();
    logger.fine('element unmounted');

    super.unmount();
  }

  @override
  bool onNotification(Notification notification) {
    if (notification is! LocalCommand) {
      return false;
    }

    if (!_actor.canHandle(notification)) {
      logger.fine('no handler found for $notification');
      return false;
    }

    _actor.handle(notification);
    return true;
  }

  @override
  void notifyClients(covariant ProxyWidget oldWidget) {}

  @override
  void add<C extends LocalCommand>(FluirActorHandler<C> handler) {
    _actor.addHandler<C>(handler);
  }

  late FluirActor _actor;
}

abstract class WidgetActor extends StatefulWidget {
  WidgetActor({super.key});
}

abstract class WidgetActorState<T extends WidgetActor> extends State<T>
    implements FluirActorHandlers, FluirActorContext {
  WidgetActorState() {
    logger = Logger('Fluir.Actor.$runtimeType');
    _actor = FluirActor(name: runtimeType.toString(), context: this);
  }

  late final Logger logger;

  FluirClientSystem get system => FluirSystemProvider.of(context);

  void initHandlers(FluirActorHandlers handlers);

  @override
  void initState() {
    super.initState();
    initHandlers(this);
    _register();
  }

  @override
  void dispose() {
    _unregister();

    super.dispose();
  }

  @override
  void add<C extends LocalCommand>(FluirActorHandler<C> handler) {
    _actor.addHandler<C>(handler);
  }

  void handle(LocalCommand cmd) {
    _actor.handle(cmd);
  }

  void _register() {
    context.visitAncestorElements((element) {
      if (element is FluirFlowElement) {
        element.register(_actor);
        _flow = element;
        return false;
      }

      return true;
    });

    assert(_flow != null, 'no flow found');
  }

  void _unregister() {
    assert(_flow != null);

    _flow!.unregister(_actor);
    _flow = null;
  }

  late final FluirActor _actor;
  FluirFlowElement? _flow;
}
