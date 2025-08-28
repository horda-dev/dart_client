import 'package:horda_core/horda_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'message.dart';
import 'provider.dart';
import 'query.dart';

extension FluirModelExtensions on BuildContext {
  void logout() {
    final system = FluirSystemProvider.of(this);
    system.changeAuthState(null);
    system.reopen(
      IncognitoConfig(
        url: system.connectionConfig.url,
        apiKey: system.connectionConfig.apiKey,
      ),
    );
    system.clearStore();
  }

  FluirAuthState get fluirAuthState {
    return FluirSystemProvider.authStateOf(this);
  }

  FluirConnectionState get fluirConnectionState {
    return FluirSystemProvider.connectionStateOf(this);
  }

  String? get fluirAuthUserId {
    var state = fluirAuthState;
    return switch (state) {
      AuthStateValidating() => null,
      AuthStateIncognito() => null,
      AuthStateLoggedIn() => state.userId,
    };
  }
}

extension MessageExtensions on BuildContext {
  void dispatch(LocalMessage msg) {
    dispatchNotification(msg);
    FluirSystemProvider.of(this).analyticsService?.reportMessage(msg);
    Logger('Fluir').info('${widget.runtimeType} dispatched $msg');
  }
}

typedef ListSelector<Q extends ActorQuery> = ActorListView Function(Q q);

typedef RefSelector<P extends ActorQuery, C extends ActorQuery> =
    ActorRefView<C> Function(P q);

typedef RefIdSelector<Q extends ActorQuery> = ActorRefView Function(Q q);

typedef ValueSelector<Q extends ActorQuery, T> =
    ActorValueView<T> Function(Q q);

typedef CounterSelector<Q extends ActorQuery> = ActorCounterView Function(Q q);

typedef ListItemSelector<L extends ActorQuery, I extends ActorQuery> =
    ActorListView<I> Function(L q);

extension ActorViewQueryExtensions on BuildContext {
  ActorQueryProvider runActorQuery({
    required EntityId actorId,
    required ActorQuery query,
    required Widget child,
  }) {
    return ActorQueryProvider(
      actorId: actorId,
      query: query,
      system: FluirSystemProvider.of(this),
      child: child,
    );
  }

  ActorQueryProvider actorQuery({
    required EntityId actorId,
    required ActorQuery query,
    required Widget child,
    Widget? loading,
    Widget? error,
  }) {
    return ActorQueryProvider(
      actorId: actorId,
      query: query,
      system: FluirSystemProvider.of(this),
      child: Builder(
        builder: (context) {
          var query = context.query<ActorQuery>();
          switch (query.state()) {
            case ActorQueryState.created:
              return loading ??
                  Container(
                    alignment: Alignment.center,
                    child: CupertinoActivityIndicator(),
                  );
            case ActorQueryState.error:
              return error ??
                  Container(alignment: Alignment.center, child: Text(':('));
            case ActorQueryState.loaded:
              return child;
            case ActorQueryState.stopped:
              return Container(alignment: Alignment.center, child: Text('?'));
          }
        },
      ),
    );
  }

  ActorQueryDependencyBuilder<Q> query<Q extends ActorQuery>() {
    var element = ActorQueryProvider.find<Q>(this);

    return ActorQueryDependencyBuilder<Q>._(
      _Builder.root(Q, element.host, element, this, depend: true),
    );
  }

  ActorQueryDependencyBuilder<Q> lookup<Q extends ActorQuery>() {
    var element = ActorQueryProvider.find<Q>(this);

    return ActorQueryDependencyBuilder<Q>._(
      _Builder.root(Q, element.host, element, this, depend: false),
    );
  }
}

class ActorQueryDependencyBuilder<Q extends ActorQuery> {
  ActorQueryDependencyBuilder._(this._builder);

  final _Builder<Q> _builder;

  ActorQueryDependencyBuilder<I> listItem<I extends ActorQuery>(
    ListItemSelector<Q, I> sel,
    int index,
  ) {
    return ActorQueryDependencyBuilder._(
      _builder.listItem(sel, index, maybe: false),
    );
  }

  ActorQueryDependencyBuilder<C> ref<C extends ActorQuery>(
    RefSelector<Q, C> sel,
  ) {
    return ActorQueryDependencyBuilder._(_builder.ref(sel, maybe: false));
  }

  MaybeActorQueryDependencyBuilder<C> maybeRef<C extends ActorQuery>(
    RefSelector<Q, C> sel,
  ) {
    return MaybeActorQueryDependencyBuilder._(_builder.ref(sel, maybe: true));
  }

  // leaf

  EntityId id() {
    return _builder.id()!;
  }

  ActorQueryState state() {
    return _builder.state()!;
  }

  T value<T>(ValueSelector<Q, T> sel) {
    var val = _builder.value(sel);
    if (val == null) {
      if (null is T) {
        return null as T;
      }
      throw FluirError('value view is null');
    }
    return val;
  }

  int counter(CounterSelector<Q> sel) {
    return _builder.counter(sel)!;
  }

  EntityId refId(RefIdSelector<Q> sel) {
    return _builder.refId(sel);
  }

  T refValueAttr<T>(RefIdSelector<Q> sel, String attrName) {
    return _builder.refValAttr<T>(sel, attrName);
  }

  EntityId? maybeRefId(RefIdSelector<Q> sel) {
    return _builder.maybeRefId(sel);
  }

  T? maybeRefValueAttr<T>(RefIdSelector<Q> sel, String attrName) {
    return _builder.maybeRefValAttr<T>(sel, attrName);
  }

  EntityId listItemId(ListSelector<Q> sel, int index) {
    return _builder.listItemId(sel, index)!;
  }

  T listItemValueAttr<T>(ListSelector<Q> sel, String attrName, int index) {
    return _builder.listItemValAttr<T>(sel, attrName, index);
  }

  int listItemCounterAttr(ListSelector<Q> sel, String attrName, int index) {
    return _builder.listItemCounterAtt(sel, attrName, index);
  }

  List<EntityId> listItems(ListSelector<Q> sel) {
    return _builder.listItems(sel);
  }

  int listLength(ListSelector<Q> sel) {
    return _builder.listLength(sel)!;
  }

  ActorQueryValueHandlerBuilder<Q, T> addValueHandler<T>(
    ValueSelector<Q, T> sel,
  ) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return ActorQueryValueHandlerBuilder<Q, T>(_builder, sel);
  }

  ActorQueryRefHandlerBuilder addRefHandler(RefIdSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return ActorQueryRefHandlerBuilder<Q>(_builder, sel);
  }

  ActorQueryCounterHandlerBuilder addCounterHandler(CounterSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return ActorQueryCounterHandlerBuilder<Q>(_builder, sel);
  }

  ActorQueryListHandlerBuilder addListHandler(ListSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return ActorQueryListHandlerBuilder<Q>(_builder, sel);
  }
}

typedef ChangeHandler<C extends Change> = void Function(C change);

class ActorQueryValueHandlerBuilder<Q extends ActorQuery, T> {
  ActorQueryValueHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final ValueSelector<Q, T> _sel;

  void onValueChanged(ChangeHandler<ValueViewChanged<T>> handler) {
    return _builder.addChangeHandler<ValueViewChanged<T>>(
      _sel,
      ValueViewChangedHandler<T>(handler),
    );
  }
}

class ActorQueryRefHandlerBuilder<Q extends ActorQuery> {
  ActorQueryRefHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final RefIdSelector<Q> _sel;

  void onRefValueChanged(ChangeHandler<RefViewChanged> handler) {
    return _builder.addChangeHandler<RefViewChanged>(_sel, handler);
  }
}

class ActorQueryCounterHandlerBuilder<Q extends ActorQuery> {
  ActorQueryCounterHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final CounterSelector<Q> _sel;

  void onIncremented(ChangeHandler<CounterViewIncremented> handler) {
    _builder.addChangeHandler<CounterViewIncremented>(_sel, handler);
  }

  void onDecremented(ChangeHandler<CounterViewDecremented> handler) {
    _builder.addChangeHandler<CounterViewDecremented>(_sel, handler);
  }

  void onReset(ChangeHandler<CounterViewReset> handler) {
    _builder.addChangeHandler<CounterViewReset>(_sel, handler);
  }
}

class ActorQueryListHandlerBuilder<Q extends ActorQuery> {
  ActorQueryListHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final ListSelector<Q> _sel;

  void onItemAdded(ChangeHandler<ListViewItemAdded> handler) {
    _builder.addChangeHandler<ListViewItemAdded>(_sel, handler);
  }

  void onItemRemoved(ChangeHandler<ListViewItemRemoved> handler) {
    _builder.addChangeHandler<ListViewItemRemoved>(_sel, handler);
  }

  void onItemAddedIfAbsent(ChangeHandler<ListViewItemAddedIfAbsent> handler) {
    _builder.addChangeHandler<ListViewItemAddedIfAbsent>(_sel, handler);
  }

  void onCleared(ChangeHandler<ListViewCleared> handler) {
    _builder.addChangeHandler<ListViewCleared>(_sel, handler);
  }
}

class MaybeActorQueryDependencyBuilder<Q extends ActorQuery> {
  MaybeActorQueryDependencyBuilder._(this._builder);

  final _Builder<Q> _builder;

  MaybeActorQueryDependencyBuilder<I> listItem<I extends ActorQuery>(
    ListItemSelector<Q, I> sel,
    int index,
  ) {
    return MaybeActorQueryDependencyBuilder._(
      _builder.listItem(sel, index, maybe: true),
    );
  }

  MaybeActorQueryDependencyBuilder<C> ref<C extends ActorQuery>(
    RefSelector<Q, C> sel,
  ) {
    return MaybeActorQueryDependencyBuilder._(_builder.ref(sel, maybe: true));
  }

  // leaf

  ActorQueryState? state() {
    return _builder.state();
  }

  T? value<T>(ValueSelector<Q, T> sel) {
    return _builder.value(sel);
  }

  int? counter(CounterSelector<Q> sel) {
    return _builder.counter(sel);
  }

  EntityId? refId(RefIdSelector<Q> sel) {
    return _builder.maybeRefId(sel);
  }

  T? refValueAttr<T>(RefIdSelector<Q> sel, String attrName) {
    throw _builder.maybeRefValAttr(sel, attrName);
  }

  EntityId? listItemId(ListSelector<Q> sel, int index) {
    return _builder.listItemId(sel, index);
  }

  int? listLength(ListSelector<Q> sel) {
    return _builder.listLength(sel);
  }
}

class _Builder<Q extends ActorQuery> {
  _Builder.root(
    this.queryType,
    this.host,
    this.element,
    this.context, {
    required this.depend,
  }) : path = ActorQueryPath.empty(),
       maybe = false;

  _Builder.child(
    this.queryType,
    this.path,
    this.host,
    this.element,
    this.context, {
    required this.depend,
    required this.maybe,
  });

  final bool depend;

  final bool maybe;

  final ActorQueryHost host;

  final ActorQueryProviderElement element;

  final BuildContext context;

  final ActorQueryPath path;

  final Type queryType;

  _Builder<I> listItem<I extends ActorQuery>(
    ListItemSelector<Q, I> sel,
    int index, {
    required bool maybe,
  }) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    var list = host.children[view.name] as ActorListViewHost;

    if (index >= list.items.length) {
      throw FluirError('index $index is out of bounds for ${list.debugId}');
    }

    var itemId = list.items.elementAt(index);
    newPath = newPath.append(ActorQueryPath.root(itemId));

    return _Builder.child(
      queryType,
      newPath,
      list.itemHost(index),
      element,
      context,
      depend: depend,
      maybe: maybe,
    );
  }

  _Builder<C> ref<C extends ActorQuery>(
    RefSelector<Q, C> sel, {
    required bool maybe,
  }) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    var refHost = host.children[view.name];
    if (refHost == null) {
      throw FluirError('no $newPath view found in ${host.actorId} query');
    }

    return _Builder.child(
      queryType,
      newPath,
      (refHost as ActorRefViewHost).child,
      element,
      context,
      depend: depend,
      maybe: maybe,
    );
  }

  // leaf

  EntityId? id() {
    var id = host.actorId;
    if (id == null && !maybe) {
      throw FluirError('query ${host.debugId} actor id is null');
    }

    return id;
  }

  ActorQueryState? state() {
    var newPath = path.append(ActorQueryPath.state());

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    return host.state;
  }

  T? value<T>(ValueSelector<Q, T> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'value view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorValueViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorValueViewHost',
      );
    }

    if (child.value == null) {
      if (maybe) {
        return null;
      }

      if (null is T) {
        return null as T;
      }

      throw FluirError(
        'value view ${child.debugId} value is null for $newPath',
      );
    }

    if (child.value is! T) {
      throw FluirError(
        'wrong value view type found ${child.value.runtimeType}, expected: $T',
      );
    }

    return child.value;
  }

  int? counter(CounterSelector<Q> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'counter view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorCounterViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorCounterViewHost',
      );
    }

    if (child.value == null && !maybe) {
      throw FluirError('counter view ${child.debugId} value is null');
    }

    return child.value;
  }

  EntityId refId(RefIdSelector<Q> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'ref view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorRefViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorRefViewHost',
      );
    }

    if (child.refId == null && !maybe) {
      throw FluirError('ref value for ${view.name} in ${host.debugId} is null');
    }

    return child.refId!;
  }

  EntityId? maybeRefId(RefIdSelector<Q> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'ref view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorRefViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorRefViewHost',
      );
    }

    return child.refId;
  }

  EntityId? listItemId(ListSelector<Q> sel, int index) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'list view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorListViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorListViewHost',
      );
    }

    if (index >= child.items.length) {
      throw FluirError('index $index is out of bounds for ${child.debugId}');
    }

    return child.items.elementAt(index);
  }

  List<EntityId> listItems(ListSelector<Q> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'list view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorListViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorListViewHost',
      );
    }

    return List.unmodifiable(child.items);
  }

  int? listLength(ListSelector<Q> sel) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'list view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorListViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorListViewHost',
      );
    }

    return child.items.length;
  }

  T refValAttr<T>(RefIdSelector<Q> sel, String attrName) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'ref view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorRefViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorRefViewHost',
      );
    }

    if (!child.hasAttribute(attrName) && !maybe) {
      throw FluirError('no attribute $attrName found in ${host.debugId}');
    }

    return child.valueAttr<T>(attrName);
  }

  T? maybeRefValAttr<T>(RefIdSelector<Q> sel, String attrName) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'ref view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorRefViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorRefViewHost',
      );
    }

    if (!child.hasAttribute(attrName)) {
      return null;
    }

    return child.valueAttr<T>(attrName);
  }

  T listItemValAttr<T>(ListSelector<Q> sel, String attrName, int index) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'list view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorListViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorListViewHost',
      );
    }

    return child.valueAttr<T>(attrName, index);
  }

  int listItemCounterAtt(ListSelector<Q> sel, String attrName, int index) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    var child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'list view host for ${view.name} not found in ${host.debugId}',
      );
    }

    if (child is! ActorListViewHost) {
      throw FluirError(
        'wrong host type found ${child.runtimeType}, expected: ActorListViewHost',
      );
    }

    return child.counterAttr(attrName, index);
  }

  void addChangeHandler<C extends Change>(
    ActorView Function(Q) sel,
    dynamic handler,
  ) {
    final view = sel(host.query as Q);
    final child = host.children[view.name];

    if (child == null) {
      throw FluirError(
        'view host for ${view.name} not found in ${host.debugId}',
      );
    }

    final state = (context as StatefulElement).state as ChangeHandlerState;

    state.addHost(child);

    // Strip generic type from ValueViewChanged
    final changeType = C.toString().startsWith('ValueViewChanged')
        ? ValueViewChanged
        : C;

    child.addChangeHandler(changeType, handler, state);
  }
}

/// State which unregisters it's [ChangeHandler]s on dispose.
///
/// Context query builder functions which add handlers, call [addHost].
/// This way the state can request removal of it's handlers on [dispose].
///
/// In case an [ActorViewHost] is stopped while this [ChangeHandlerState] still exists,
/// the host will call [removeHost]. So the stopped host is no longer referred to.
mixin ChangeHandlerState<T extends StatefulWidget> on State<T> {
  @override
  void dispose() {
    for (final host in _hosts) {
      host.removeChangeHandlers(this);
    }

    _hosts.clear();

    super.dispose();
  }

  void addHost(ActorViewHost host) {
    _hosts.add(host);
  }

  void removeHost(ActorViewHost host) {
    _hosts.remove(host);
  }

  final _hosts = <ActorViewHost>{};
}

/// A wrapper for [ValueViewChanged] handler. It's purpose is to make a properly typed [ValueViewChanged] before
/// passing it to the [handler].
///
/// Anonymous function could be used instead, but we won't be able to check if the handler
/// was already added.
class ValueViewChangedHandler<T> {
  ValueViewChangedHandler(this.handler);

  final Function handler;

  @override
  bool operator ==(Object other) {
    if (other is ValueViewChangedHandler) {
      return this.handler == other.handler;
    }

    return super == other;
  }

  @override
  int get hashCode => handler.hashCode;

  void call(ValueViewChanged change) {
    final c = ValueViewChanged<T>(change.newValue);
    return handler(c);
  }
}
