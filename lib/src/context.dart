import 'package:horda_core/horda_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'message.dart';
import 'provider.dart';
import 'query.dart';

/// Extension providing authentication and connection state access for Flutter widgets.
///
/// Adds convenient methods to [BuildContext] for accessing Horda authentication
/// and connection states, as well as logout functionality.
extension HordaModelExtensions on BuildContext {
  Future<void> logout() async {
    final system = HordaSystemProvider.of(this);
    system.changeAuthState(null);
    system.clearStore();
    await system.reopen();
  }

  Future<void> reopenConnection() async {
    final system = HordaSystemProvider.of(this);
    system.clearStore();
    await system.reopen();
  }

  HordaAuthState get hordaAuthState {
    return HordaSystemProvider.authStateOf(this);
  }

  HordaConnectionState get hordaConnectionState {
    return HordaSystemProvider.connectionStateOf(this);
  }

  String? get hordaAuthUserId {
    final state = hordaAuthState;
    return switch (state) {
      AuthStateValidating() => null,
      AuthStateIncognito() => null,
      AuthStateLoggedIn() => state.userId,
    };
  }
}

/// Extension for dispatching local messages within the Flutter app.
///
/// Provides methods to dispatch local messages that can be handled by
/// notification listeners and analytics services.
extension LocalMessageExtensions on BuildContext {
  void dispatchLocal(LocalMessage msg) {
    dispatchNotification(msg);
    HordaSystemProvider.of(this).analyticsService?.reportMessage(msg);
    Logger('Fluir').info('${widget.runtimeType} dispatched $msg');
  }
}

/// Extension for sending remote messages to the Horda backend.
///
/// Provides convenient [BuildContext] methods for sending commands and events
/// to the Horda backend. These methods enable client-server communication with
/// type-safe response handling.
extension RemoteMessageExtensions on BuildContext {
  /// Dispatches a remote event and waits for the backend flow processing result.
  ///
  /// Sends [event] to the Horda backend where it will be processed by the
  /// appropriate business process flow. Returns a [ProcessResult] indicating
  /// success or failure of the backend processing.
  ///
  /// This is useful when you need confirmation that the backend has processed
  /// the event, but don't expect a typed response event.
  ///
  /// Example:
  /// ```dart
  /// final result = await context.runProcess(MyEvent(...));
  /// if (result.isError) {
  ///   // Event was processed with an error
  /// }
  /// ```
  Future<ProcessResult> runProcess(RemoteEvent event) {
    return HordaSystemProvider.of(this).runProcess(event);
  }

  /// Sends a command to an entity without waiting for a response.
  ///
  /// Fire-and-forget method that sends [cmd] to the entity identified by
  /// [name] and [id]. Use this when you don't need to wait for the result
  /// or response from the backend.
  ///
  /// Parameters:
  /// - [name] - The entity type name as registered on the backend
  /// - [id] - The unique identifier of the target entity
  /// - [cmd] - The command to send to the entity
  ///
  /// Example:
  /// ```dart
  /// context.sendEntity(
  ///   name: 'user',
  ///   id: userId,
  ///   cmd: UpdateProfileCommand(firstName: 'John'),
  /// );
  /// ```
  void sendEntity({
    required String name,
    required EntityId id,
    required RemoteCommand cmd,
  }) {
    HordaSystemProvider.of(this).sendEntity(
      name: name,
      id: id,
      cmd: cmd,
    );
  }

  /// Sends a command to an entity and waits for a typed response event.
  ///
  /// Sends [cmd] to the entity identified by [name] and [id], then waits
  /// for the backend to respond with an event of type [E]. The [fac] factory
  /// function is used to deserialize the JSON response into the expected
  /// event type.
  ///
  /// Throws [FluirError] if:
  /// - The backend returns an error response
  /// - The response event type doesn't match the expected type [E]
  ///
  /// Parameters:
  /// - [name] - The entity type name as registered on the backend
  /// - [id] - The unique identifier of the target entity
  /// - [cmd] - The command to send to the entity
  /// - [fac] - Factory function to deserialize the JSON response into type [E]
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final event = await context.callEntity<ProfileUpdatedEvent>(
  ///     name: 'user',
  ///     id: userId,
  ///     cmd: UpdateProfileCommand(firstName: 'John'),
  ///     fac: ProfileUpdatedEvent.fromJson,
  ///   );
  ///   // Handle the response event
  /// } on FluirError catch (e) {
  ///   // Handle error
  /// }
  /// ```
  Future<E> callEntity<E extends RemoteEvent>({
    required String name,
    required EntityId id,
    required RemoteCommand cmd,
    required FromJsonFun<E> fac,
  }) {
    return HordaSystemProvider.of(this).callEntity(
      name: name,
      id: id,
      cmd: cmd,
      fac: fac,
    );
  }
}

/// Selector function for accessing list views within entity queries.
///
/// Used to specify which [EntityListView] to access from a query.
typedef ListSelector<Q extends EntityQuery> = EntityListView Function(Q q);

/// Selector function for accessing reference views within entity queries.
///
/// Used to specify which [EntityRefView] to access from a parent query.
typedef RefSelector<P extends EntityQuery, C extends EntityQuery> =
    EntityRefView<C> Function(P q);

/// Selector function for accessing reference view IDs within entity queries.
///
/// Used to access the ID of a referenced entity without the full query data.
typedef RefIdSelector<Q extends EntityQuery> = EntityRefView Function(Q q);

/// Selector function for accessing value views within entity queries.
///
/// Used to specify which [EntityValueView] to access from a query.
typedef ValueSelector<Q extends EntityQuery, T> =
    EntityValueView<T> Function(Q q);

/// Selector function for accessing counter views within entity queries.
///
/// Used to specify which [EntityCounterView] to access from a query.
typedef CounterSelector<Q extends EntityQuery> =
    EntityCounterView Function(Q q);

/// Selector function for accessing individual items within list views.
///
/// Used to specify which list item to access from a list query.
typedef ListItemSelector<L extends EntityQuery, I extends EntityQuery> =
    EntityListView<I> Function(L q);

/// Extension providing entity query functionality for Flutter widgets.
///
/// Adds methods to [BuildContext] for running entity queries and accessing
/// query results with automatic reactive updates.
extension EntityViewQueryExtensions on BuildContext {
  EntityQueryProvider runEntityQuery({
    required EntityId entityId,
    required EntityQuery query,
    required Widget child,
  }) {
    return EntityQueryProvider(
      entityId: entityId,
      query: query,
      system: HordaSystemProvider.of(this),
      child: child,
    );
  }

  EntityQueryProvider entityQuery({
    required EntityId entityId,
    required EntityQuery query,
    required Widget child,
    Widget? loading,
    Widget? error,
  }) {
    return EntityQueryProvider(
      entityId: entityId,
      query: query,
      system: HordaSystemProvider.of(this),
      child: Builder(
        builder: (context) {
          final query = context.query<EntityQuery>();
          switch (query.state()) {
            case EntityQueryState.created:
              return loading ??
                  Container(
                    alignment: Alignment.center,
                    child: CupertinoActivityIndicator(),
                  );
            case EntityQueryState.error:
              return error ??
                  Container(alignment: Alignment.center, child: Text(':('));
            case EntityQueryState.loaded:
              return child;
            case EntityQueryState.stopped:
              return Container(alignment: Alignment.center, child: Text('?'));
          }
        },
      ),
    );
  }

  EntityQueryDependencyBuilder<Q> query<Q extends EntityQuery>() {
    var element = EntityQueryProvider.find<Q>(this);

    return EntityQueryDependencyBuilder<Q>._(
      _Builder.root(Q, element.host, element, this, depend: true),
    );
  }

  EntityQueryDependencyBuilder<Q> lookup<Q extends EntityQuery>() {
    var element = EntityQueryProvider.find<Q>(this);

    return EntityQueryDependencyBuilder<Q>._(
      _Builder.root(Q, element.host, element, this, depend: false),
    );
  }
}

/// Builder for accessing entity query data with automatic dependency tracking.
///
/// When you access query data through this builder, your widget automatically
/// becomes dependent on the queried values and will rebuild when they change.
/// This provides real-time UI updates with zero boilerplate code.
class EntityQueryDependencyBuilder<Q extends EntityQuery> {
  EntityQueryDependencyBuilder._(this._builder);

  final _Builder<Q> _builder;

  EntityQueryDependencyBuilder<I> listItemQuery<I extends EntityQuery>(
    ListItemSelector<Q, I> sel,
    int index,
  ) {
    return EntityQueryDependencyBuilder._(
      _builder.listItemQuery(sel, index, maybe: false),
    );
  }

  EntityQueryDependencyBuilder<I> listItemQueryByKey<I extends EntityQuery>(
    ListItemSelector<Q, I> sel,
    String key,
  ) {
    return EntityQueryDependencyBuilder._(
      _builder.listItemQueryByKey(sel, key, maybe: false),
    );
  }

  EntityQueryDependencyBuilder<C> ref<C extends EntityQuery>(
    RefSelector<Q, C> sel,
  ) {
    return EntityQueryDependencyBuilder._(_builder.ref(sel, maybe: false));
  }

  MaybeEntityQueryDependencyBuilder<C> maybeRef<C extends EntityQuery>(
    RefSelector<Q, C> sel,
  ) {
    return MaybeEntityQueryDependencyBuilder._(_builder.ref(sel, maybe: true));
  }

  // leaf

  EntityId id() {
    return _builder.id()!;
  }

  EntityQueryState state() {
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

  ListItem listItem(ListSelector<Q> sel, int index) {
    return _builder.listItem(sel, index);
  }

  T listItemValueAttr<T>(ListSelector<Q> sel, String attrName, int index) {
    return _builder.listItemValAttr<T>(sel, attrName, index);
  }

  int listItemCounterAttr(ListSelector<Q> sel, String attrName, int index) {
    return _builder.listItemCounterAttr(sel, attrName, index);
  }

  EntityId listItemValue(ListSelector<Q> sel, String key) {
    return _builder.listItemValue(sel, key);
  }

  T listItemValueAttrByKey<T>(
    ListSelector<Q> sel,
    String attrName,
    String itemKey,
  ) {
    return _builder.listItemValAttrByKey<T>(sel, attrName, itemKey);
  }

  int listItemCounterAttrByKey(
    ListSelector<Q> sel,
    String attrName,
    String itemKey,
  ) {
    return _builder.listItemCounterAttrByKey(sel, attrName, itemKey);
  }

  bool listContainsKey(ListSelector<Q> sel, String key) {
    return _builder.listContainsKey(sel, key);
  }

  List<ListItem> listItems(ListSelector<Q> sel) {
    return _builder.listItems(sel);
  }

  int listLength(ListSelector<Q> sel) {
    return _builder.listLength(sel)!;
  }

  EntityQueryValueHandlerBuilder<Q, T> addValueHandler<T>(
    ValueSelector<Q, T> sel,
  ) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return EntityQueryValueHandlerBuilder<Q, T>(_builder, sel);
  }

  EntityQueryRefHandlerBuilder addRefHandler(RefIdSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return EntityQueryRefHandlerBuilder<Q>(_builder, sel);
  }

  EntityQueryCounterHandlerBuilder addCounterHandler(CounterSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return EntityQueryCounterHandlerBuilder<Q>(_builder, sel);
  }

  EntityQueryListHandlerBuilder addListHandler(ListSelector<Q> sel) {
    final context = _builder.context;

    if (context is! StatefulElement || context.state is! ChangeHandlerState) {
      throw FluirError(
        'Change handler API can be only used in stateful widgets with $ChangeHandlerState mixin',
      );
    }

    return EntityQueryListHandlerBuilder<Q>(_builder, sel);
  }
}

/// Handler function for reacting to specific view changes.
///
/// Used with value change handlers when you need to execute custom code
/// in response to data changes, such as triggering animations or logging.
typedef ChangeHandler<C extends Change> = void Function(C change);

/// Builder for setting up value change handlers on entity queries.
///
/// Allows you to register handlers that execute when specific value views
/// change, useful for triggering animations or other reactive behavior.
class EntityQueryValueHandlerBuilder<Q extends EntityQuery, T> {
  EntityQueryValueHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final ValueSelector<Q, T> _sel;

  void onValueChanged(ChangeHandler<ValueViewChanged<T>> handler) {
    return _builder.addChangeHandler<ValueViewChanged<T>>(
      _sel,
      ValueViewChangedHandler<T>(handler),
    );
  }
}

/// Builder for setting up reference change handlers on entity queries.
///
/// Allows you to register handlers that execute when reference views
/// change their target entity.
class EntityQueryRefHandlerBuilder<Q extends EntityQuery> {
  EntityQueryRefHandlerBuilder(this._builder, this._sel);

  final _Builder<Q> _builder;
  final RefIdSelector<Q> _sel;

  void onRefValueChanged(ChangeHandler<RefViewChanged> handler) {
    return _builder.addChangeHandler<RefViewChanged>(_sel, handler);
  }
}

/// Builder for setting up counter change handlers on entity queries.
///
/// Allows you to register handlers for counter increment, decrement,
/// and reset operations.
class EntityQueryCounterHandlerBuilder<Q extends EntityQuery> {
  EntityQueryCounterHandlerBuilder(this._builder, this._sel);

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

/// Builder for setting up list change handlers on entity queries.
///
/// Allows you to register handlers for list operations like item addition,
/// removal, and clearing.
class EntityQueryListHandlerBuilder<Q extends EntityQuery> {
  EntityQueryListHandlerBuilder(this._builder, this._sel);

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

/// Builder for accessing potentially null entity query data.
///
/// Similar to [EntityQueryDependencyBuilder] but handles cases where
/// the queried data might be null (e.g., optional references).
class MaybeEntityQueryDependencyBuilder<Q extends EntityQuery> {
  MaybeEntityQueryDependencyBuilder._(this._builder);

  final _Builder<Q> _builder;

  MaybeEntityQueryDependencyBuilder<I> listItemQuery<I extends EntityQuery>(
    ListItemSelector<Q, I> sel,
    int index,
  ) {
    return MaybeEntityQueryDependencyBuilder._(
      _builder.listItemQuery(sel, index, maybe: true),
    );
  }

  MaybeEntityQueryDependencyBuilder<I>
  listItemQueryByKey<I extends EntityQuery>(
    ListItemSelector<Q, I> sel,
    String key,
  ) {
    return MaybeEntityQueryDependencyBuilder._(
      _builder.listItemQueryByKey(sel, key, maybe: true),
    );
  }

  MaybeEntityQueryDependencyBuilder<C> ref<C extends EntityQuery>(
    RefSelector<Q, C> sel,
  ) {
    return MaybeEntityQueryDependencyBuilder._(_builder.ref(sel, maybe: true));
  }

  // leaf

  EntityQueryState? state() {
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

  ListItem? listItem(ListSelector<Q> sel, int index) {
    return _builder.listItem(sel, index);
  }

  int? listLength(ListSelector<Q> sel) {
    return _builder.listLength(sel);
  }
}

/// Internal builder class for accessing query data with dependency tracking.
///
/// Handles the complex logic of navigating query paths, establishing
/// dependencies, and retrieving data from entity view hosts.
class _Builder<Q extends EntityQuery> {
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

  _Builder<I> listItemQuery<I extends EntityQuery>(
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

    var listItem = list.items.elementAt(index);
    var itemId = listItem.value;
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

  _Builder<I> listItemQueryByKey<I extends EntityQuery>(
    ListItemSelector<Q, I> sel,
    String key, {
    required bool maybe,
  }) {
    var view = sel(host.query as Q);
    var newPath = path.append(ActorQueryPath.root(view.name));

    var list = host.children[view.name] as ActorListViewHost;

    // Find the index by key
    final index = list.items.toList().indexWhere((item) => item.key == key);

    if (index == -1) {
      throw FluirError(
        'list item with key "$key" not found in ${list.debugId}',
      );
    }

    var listItem = list.items.elementAt(index);
    var itemId = listItem.value;
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

  _Builder<C> ref<C extends EntityQuery>(
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

  EntityQueryState? state() {
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

  ListItem listItem(ListSelector<Q> sel, int index) {
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
      if (maybe) {
        throw FluirError('index $index is out of bounds for ${child.debugId}');
      }
      throw FluirError('index $index is out of bounds for ${child.debugId}');
    }

    return child.items.elementAt(index);
  }

  EntityId listItemValue(ListSelector<Q> sel, String key) {
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

    // Find item by key
    final item = child.items.firstWhere(
      (item) => item.key == key,
      orElse: () => throw FluirError(
        'list item with key "$key" not found in ${child.debugId}',
      ),
    );

    return item.value;
  }

  bool listContainsKey(ListSelector<Q> sel, String key) {
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

    return child.items.any((item) => item.key == key);
  }

  List<ListItem> listItems(ListSelector<Q> sel) {
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

  T listItemValAttrByKey<T>(
    ListSelector<Q> sel,
    String attrName,
    String itemKey,
  ) {
    final view = sel(host.query as Q);
    final newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    final child = host.children[view.name];

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

    return child.valueAttrByKey<T>(attrName, itemKey);
  }

  int listItemCounterAttr(ListSelector<Q> sel, String attrName, int index) {
    final view = sel(host.query as Q);
    final newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    final child = host.children[view.name];

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

  int listItemCounterAttrByKey(
    ListSelector<Q> sel,
    String attrName,
    String itemKey,
  ) {
    final view = sel(host.query as Q);
    final newPath = path.append(ActorQueryPath.root(view.name));

    if (depend) {
      element.depend(queryType, newPath, context);
    }

    final child = host.children[view.name];

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

    return child.counterAttrByKey(attrName, itemKey);
  }

  void addChangeHandler<C extends Change>(
    EntityView Function(Q) sel,
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
/// State mixin that automatically manages change handler lifecycle.
///
/// Mix this into your stateful widget states when using change handlers.
/// It ensures handlers are properly cleaned up when the widget is disposed.
///
/// Example:
/// ```dart
/// class _MyWidgetState extends State<MyWidget>
///     with ChangeHandlerState<MyWidget> {
///   // Your widget implementation
/// }
/// ```
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
/// Wrapper for [ValueViewChanged] handlers with proper type safety.
///
/// Ensures that value change handlers receive correctly typed change events.
/// This wrapper is used internally to maintain type safety when registering
/// change handlers.
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
