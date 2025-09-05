import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'process.dart';
import 'message.dart';
import 'provider.dart';
import 'system.dart';

typedef HordaEntityHandler<C extends LocalCommand> =
    Future<void> Function(C cmd, HordaEntityContext context);

abstract class HordaEntityContext {
  Logger get logger;
}

class HordaEntity {
  HordaEntity({required this.name, required this.context});

  final String name;

  final HordaEntityContext context;

  Iterable<Type> get handleCommands => _handlers.keys;

  void addHandler<C extends LocalCommand>(HordaEntityHandler<C> handler) {
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

abstract class HordaEntityHandlers {
  void add<C extends LocalCommand>(HordaEntityHandler<C> handler);
}

abstract class ProxyEntity extends ProxyWidget {
  ProxyEntity({super.key, required super.child});

  void initHandlers(HordaEntityHandlers handlers);

  @override
  Element createElement() {
    return _ProxyEntityElement(this);
  }
}

class _ProxyEntityElement extends ProxyElement
    with NotifiableElementMixin
    implements HordaEntityContext, HordaEntityHandlers {
  _ProxyEntityElement(super.widget)
    : logger = Logger('Fluir.Actor.${widget.runtimeType}') {
    _actor = HordaEntity(name: widget.runtimeType.toString(), context: this);
  }

  @override
  final Logger logger;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);

    (widget as ProxyEntity).initHandlers(this);
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
  void add<C extends LocalCommand>(HordaEntityHandler<C> handler) {
    _actor.addHandler<C>(handler);
  }

  late HordaEntity _actor;
}

abstract class WidgetEntity extends StatefulWidget {
  WidgetEntity({super.key});
}

abstract class WidgetEntityState<T extends WidgetEntity> extends State<T>
    implements HordaEntityHandlers, HordaEntityContext {
  WidgetEntityState() {
    logger = Logger('Fluir.Actor.$runtimeType');
    _actor = HordaEntity(name: runtimeType.toString(), context: this);
  }

  late final Logger logger;

  HordaClientSystem get system => HordaSystemProvider.of(context);

  void initHandlers(HordaEntityHandlers handlers);

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
  void add<C extends LocalCommand>(HordaEntityHandler<C> handler) {
    _actor.addHandler<C>(handler);
  }

  void handle(LocalCommand cmd) {
    _actor.handle(cmd);
  }

  void _register() {
    context.visitAncestorElements((element) {
      if (element is HordaProcessElement) {
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

  late final HordaEntity _actor;
  HordaProcessElement? _flow;
}
