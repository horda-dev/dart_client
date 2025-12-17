import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'connection.dart';
import 'context.dart';
import 'devtool.dart';
import 'provider.dart';
import 'system.dart';

/// Base class for defining entity queries in the Horda Client SDK.
///
/// Entity queries define which views to retrieve from entities on the backend.
/// They map directly to EntityViewGroups defined on the server, creating a
/// strongly-typed contract between your Flutter app and backend.
///
/// Example:
/// ```dart
/// class CounterQuery extends EntityQuery {
///   final counterName = EntityValueView<String>('name');
///   final counterValue = EntityCounterView('value');
///
///   @override
///   void initViews(EntityQueryGroup views) {
///     views..add(counterName)..add(counterValue);
///   }
/// }
/// ```
abstract class EntityQuery implements EntityQueryGroup {
  EntityQuery() {
    initViews(this);
  }

  String get name => '$runtimeType';

  String get entityName;

  Map<String, EntityView> get views => _views;

  @override
  void add(EntityView view) {
    _views[view.name] = view;
  }

  QueryDefBuilder queryBuilder() {
    final qb = QueryDefBuilder(entityName);

    for (final v in _views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  void initViews(EntityQueryGroup views);

  ActorQueryHost rootHost(String parentLoggerName, HordaClientSystem system) {
    return ActorQueryHost(parentLoggerName, null, this, system);
  }

  ActorQueryHost childHost(
    String parentLoggerName,
    ActorViewHost parent,
    HordaClientSystem system,
  ) {
    return ActorQueryHost(parentLoggerName, parent, this, system);
  }

  final _views = <String, EntityView>{};
}

/// Empty query implementation that retrieves no views.
///
/// Used as a placeholder when you need a query but don't want to
/// retrieve any specific data from the entity.
class EmptyQuery extends EntityQuery {
  @override
  String get entityName => '';

  @override
  void initViews(EntityQueryGroup views) {}
}

/// Function type for converting raw view values to typed values.
///
/// Used internally by entity views to transform data received from
/// the backend into the expected Dart types.
typedef ViewConvertFunc = dynamic Function(dynamic val);

dynamic _identity(dynamic val) => val;

/// Base class for all entity view types.
///
/// Entity views represent specific data fields that can be queried from
/// entities. Each view type (value, counter, reference, list) provides
/// different capabilities for data access and real-time updates.
abstract class EntityView {
  EntityView(
    this.name, {
    this.subscribe = true,
    this.nullable = false,
    this.convert = _identity,
  });

  final String name;

  final bool subscribe;

  final bool nullable;

  final ViewConvertFunc convert;

  ViewQueryDefBuilder queryBuilder();

  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    HordaClientSystem system,
  );
}

/// Function type for converting raw values to specific types.
///
/// Used by [EntityValueView] to ensure type safety when converting
/// backend data to the expected Dart type.
typedef ValueViewConvertFunc<T> = T? Function(dynamic val);

/// View for accessing single typed values from entities.
///
/// Use this view type to retrieve simple data fields like strings, numbers,
/// booleans, or other single values from entity state.
///
/// Example:
/// ```dart
/// final counterName = EntityValueView<String>('name');
/// final isActive = EntityValueView<bool>('active');
/// ```
class EntityValueView<T> extends EntityView {
  EntityValueView(
    super.name, {
    super.subscribe,
    ValueViewConvertFunc<T>? convert,
  }) : super(
         convert: convert ?? (val) => _defaultValueConvert<T>(name, val),
         nullable: null is T,
       );

  @override
  ViewQueryDefBuilder queryBuilder() {
    return ValueQueryDefBuilder(name, subscribe: subscribe);
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    HordaClientSystem system,
  ) {
    return ActorValueViewHost<T>(parentLoggerName, parent, this, system);
  }
}

T _defaultValueConvert<T>(String viewName, dynamic val) {
  if (val is! T) {
    throw FluirError('view $viewName value type is invalid $val');
  }
  return val;
}

/// Specialized view for accessing DateTime values from entities.
///
/// Automatically handles conversion from millisecond timestamps to
/// DateTime objects with proper UTC/local timezone handling.
///
/// Example:
/// ```dart
/// final createdAt = EntityDateTimeView('createdAt', isUtc: true);
/// ```
class EntityDateTimeView extends EntityValueView<DateTime> {
  EntityDateTimeView(
    super.name, {
    required this.isUtc,
    super.subscribe,
    bool nullable = false,
  }) : super(convert: (val) => dateTimeConvert(name, val, isUtc, nullable));

  final bool isUtc;
}

DateTime? dateTimeConvert(
  String viewName,
  dynamic val,
  bool isUtc,
  bool isNullable,
) {
  if (val == null) {
    if (isNullable) {
      return null;
    }

    throw FluirError('non nullable DateTime view "$viewName" is null');
  }

  if (val is! int) {
    throw FluirError('DateTime view "$viewName" value is not int "$val"');
  }

  return DateTime.fromMillisecondsSinceEpoch(val, isUtc: isUtc);
}

/// View for accessing counter values that support increment/decrement operations.
///
/// Counter views maintain integer values that can be incremented, decremented,
/// or reset. They provide real-time updates when the counter value changes.
///
/// Example:
/// ```dart
/// final likeCount = EntityCounterView('likes');
/// ```
class EntityCounterView<T> extends EntityView {
  EntityCounterView(super.name, {super.subscribe, super.nullable});

  @override
  ViewQueryDefBuilder queryBuilder() {
    return ValueQueryDefBuilder(name, subscribe: subscribe);
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    HordaClientSystem system,
  ) {
    return ActorCounterViewHost(parentLoggerName, parent, this, system);
  }
}

/// View for accessing references to other entities.
///
/// Reference views allow you to query related entities by following
/// entity relationships. The referenced entity can be queried using
/// the provided query definition.
///
/// Example:
/// ```dart
/// final userProfile = EntityRefView<ProfileQuery>(
///   'profile',
///   query: ProfileQuery(),
/// );
/// ```
class EntityRefView<S extends EntityQuery> extends EntityView {
  EntityRefView(
    super.name, {
    super.subscribe,
    super.nullable,
    required this.query,
    this.attrs = const [],
  });

  final S query;

  final List<String> attrs;

  @override
  ViewQueryDefBuilder queryBuilder() {
    final qb = RefQueryDefBuilder(query.entityName, name, attrs);

    for (final v in query.views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    HordaClientSystem system,
  ) {
    return ActorRefViewHost(parentLoggerName, parent, this, system);
  }
}

/// Base class for list view pagination.
///
/// Specifies how to paginate list query results using cursor-based pagination.
/// Use [ForwardPagination] for forward pagination or [ReversePagination] for
/// reverse pagination.
///
/// Example:
/// ```dart
/// // Forward pagination - get first 10 items
/// ForwardPagination(limitToFirst: 10)
///
/// // Forward pagination - get next 10 items after a cursor
/// ForwardPagination(startAfter: 'item-key-123', limitToFirst: 10)
///
/// // Reverse pagination - get last 20 items
/// ReversePagination(limitToLast: 20)
///
/// // Reverse pagination - get previous 20 items before a cursor
/// ReversePagination(endBefore: 'item-key-456', limitToLast: 20)
/// ```
sealed class Pagination {
  const Pagination();

  @visibleForTesting
  int get queryDefLimit;
}

/// Forward pagination parameters for list views.
///
/// Retrieves items in forward order, optionally starting after a specific cursor.
class ForwardPagination extends Pagination {
  /// Creates forward pagination parameters.
  ///
  /// [startAfter] specifies the cursor to start after (defaults to empty string).
  /// [limitToFirst] specifies the maximum number of items to return (defaults to 100).
  const ForwardPagination({
    this.startAfter = '',
    this.limitToFirst = 100,
  }) : assert(limitToFirst > 0, 'limit must be positive');

  /// Cursor for pagination - start after this item key.
  final String startAfter;

  /// Maximum number of items to return.
  final int limitToFirst;

  /// Returns the limit value to use in the query definition.
  ///
  /// Normalizes the [limitToFirst] value to ensure a positive limit:
  /// - Returns 100 if [limitToFirst] is 0
  /// - Returns the absolute value if [limitToFirst] is negative
  /// - Returns [limitToFirst] as-is if positive
  ///
  /// This getter is exposed for testing to verify query definition construction.
  @visibleForTesting
  @override
  int get queryDefLimit {
    if (limitToFirst == 0) {
      return 100;
    }

    if (limitToFirst < 0) {
      return -limitToFirst;
    }

    return limitToFirst;
  }
}

/// Reverse pagination parameters for list views.
///
/// Retrieves items in reverse order, optionally ending before a specific cursor.
class ReversePagination extends Pagination {
  /// Creates reverse pagination parameters.
  ///
  /// [endBefore] specifies the cursor to end before (defaults to empty string).
  /// [limitToLast] specifies the maximum number of items to return (defaults to 100).
  ReversePagination({
    this.endBefore = '',
    this.limitToLast = 100,
  }) : assert(limitToLast > 0, 'limit must be positive');

  /// Cursor for pagination - end before this item key.
  final String endBefore;

  /// Maximum number of items to return.
  final int limitToLast;

  /// Returns the limit value to use in the query definition for reverse pagination.
  ///
  /// Returns a negative limit value to indicate reverse order in the Horda protocol:
  /// - Returns -100 if [limitToLast] is 0
  /// - Returns the negated value if [limitToLast] is positive
  /// - Returns [limitToLast] as-is if already negative
  ///
  /// In Horda's query protocol, negative limits indicate reverse pagination (last N items).
  /// This getter is exposed for testing to verify query definition construction.
  @visibleForTesting
  @override
  int get queryDefLimit {
    if (limitToLast == 0) {
      return -100;
    }

    if (limitToLast > 0) {
      return -limitToLast;
    }

    return limitToLast;
  }
}

/// View for accessing lists of related entities.
///
/// List views allow you to query collections of related entities,
/// with each item in the list queried using the provided query definition.
/// Supports real-time updates for list operations (add, remove, clear).
/// Optionally supports pagination to limit the number of items retrieved.
///
/// Example:
/// ```dart
/// // Without pagination (uses default ForwardPagination)
/// final userFriends = EntityListView('friends', query: UserQuery());
///
/// // Forward pagination - get first 20 friends
/// final userFriends = EntityListView(
///   'friends',
///   query: UserQuery(),
///   pagination: ForwardPagination(limitToFirst: 20),
/// );
///
/// // Forward pagination - get next 20 friends after a cursor
/// final userFriends = EntityListView(
///   'friends',
///   query: UserQuery(),
///   pagination: ForwardPagination(startAfter: 'friend-key-123', limitToFirst: 20),
/// );
///
/// // Reverse pagination - get last 20 friends
/// final userFriends = EntityListView(
///   'friends',
///   query: UserQuery(),
///   pagination: ReversePagination(limitToLast: 20),
/// );
/// ```
class EntityListView<S extends EntityQuery> extends EntityView {
  EntityListView(
    String name, {
    super.subscribe,
    required this.query,
    this.attrs = const [],
    this.pagination = const ForwardPagination(),
  }) : super(name, convert: (res) => List<ListItem>.from(res));
  // above we are creating a mutable list from immutable list coming from json

  final S query;

  final List<String> attrs;

  /// Optional pagination parameters for limiting the number of items.
  final Pagination pagination;

  @override
  ViewQueryDefBuilder queryBuilder() {
    final ListQueryDefBuilder qb;

    final limit = pagination.queryDefLimit;

    switch (pagination) {
      case ForwardPagination(:final startAfter):
        qb = ListQueryDefBuilder(
          query.entityName,
          name,
          attrs,
          startAfter: startAfter,
          limit: limit,
        );
      case ReversePagination(:final endBefore):
        qb = ListQueryDefBuilder(
          query.entityName,
          name,
          attrs,
          endBefore: endBefore,
          limit: limit,
        );
    }

    for (var v in query.views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    HordaClientSystem system,
  ) {
    return ActorListViewHost(parentLoggerName, parent, this, system);
  }
}

/// Host for managing entity query execution and state.
///
/// Manages the lifecycle of entity queries including:
/// - Running queries against entities
/// - Managing view subscriptions for real-time updates
/// - Tracking query state (created, loaded, error, stopped)
/// - Coordinating with child view hosts
class ActorQueryHost {
  ActorQueryHost(
    String parentLoggerName,
    this.parent,
    this.query,
    this.system,
  ) {
    logger = Logger('$parentLoggerName.${query.name}');

    // Devtool: tracking ActorQueryHosts creation
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostCreated(path: '${logger.fullName}'),
    );

    for (var entry in query.views.entries) {
      _children[entry.key] = entry.value.childHost(
        logger.fullName,
        this,
        system,
      );
    }

    logger.info('host created');
  }

  final EntityQuery query;

  final HordaClientSystem system;

  late final Logger logger;

  ActorViewHost? parent;

  EntityId? actorId;

  EntityQueryState get state => _state;

  bool get isAttached => actorId != null;

  Map<String, ActorViewHost> get children => _children;

  String get debugId {
    return '${isAttached ? actorId : "unattached"}/${query.runtimeType}';
  }

  void watch(ActorQueryPath path, ActorQueryPathFunc cb) {
    if (path.isState) {
      _watcher = cb;
      return;
    }

    final first = path.first;

    // Must use toString explicitly, otherwise child will be null on web platform.
    final child = children[first.toString()];

    if (child == null) {
      throw FluirError('no view host found for query path $path');
    }

    child.watch(path, cb);
  }

  /// Note that on reconnect the hosts are not removed/stopped. The queries are re-run and the view hosts are re-attached.
  /// Account for that when updating [run] and [attach] logic.
  ///
  /// Ref: [FluirSystemProviderElement._reconnectionVisitor]
  Future<void> run(EntityId actorId) async {
    final qdef = query.queryBuilder().build();
    final queryKey = '$actorId/${query.name}';

    logger.fine('$actorId: running query...');
    logger.finer('$actorId: running query: ${qdef.toJson()}');

    this.actorId = actorId;

    try {
      // Use atomic query and subscribe operation
      // This prevents race conditions between query result and subscription start
      final result = await system.queryAndSubscribe(
        queryKey: queryKey,
        entityId: actorId,
        def: qdef,
      );

      logger.finer('$actorId: got query result: ${result.toJson()}');

      if (_isStopped) {
        logger.info('$actorId: run stopped');
        return;
      }

      // Attach first to set up change stream listeners
      attach(actorId, result);

      // Finalize query subscriptions
      // This will publish empty change envelopes for already-subscribed views
      // and mark the in-flight query as complete
      system.finalizeQuerySubscriptions(queryKey, subscriptions());

      logger.info('$actorId: ran');
    } catch (e) {
      _changeState(EntityQueryState.error);

      logger.severe('$actorId: query ran with error: $e');
    }
  }

  Future<void> unsubscribe() async {
    final queryKey = '$actorId/${query.name}';
    logger.fine('$actorId: unsubscribing...');

    await system.unsubscribeViews(queryKey, subscriptions());

    logger.info('$actorId: unsubscribed');
  }

  Iterable<ActorViewSub> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached query');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    var subs = <ActorViewSub>[];

    for (var child in _children.values) {
      subs.addAll(child.subscriptions());
    }

    logger.info('$actorId: got subs for $subs');

    return subs;
  }

  /// Query host can be re-attached due to a reconnect.
  ///
  /// Ref: [FluirSystemProviderElement._reconnectionVisitor]
  void attach(EntityId actorId, QueryResult result) {
    logger.fine('${this.actorId}: attaching to $actorId...');

    final oldActorId = this.actorId;
    this.actorId = actorId;

    logger.fine('$oldActorId: actorId changed to $actorId');

    for (var entry in result.views.entries) {
      var host = _children[entry.key];

      if (host == null) {
        throw FluirError(
          '${entry.key} view not found in $actorId/${query.name} query',
        );
      }

      _notLoadedChildren.add(entry.key);

      // Important to detach when switching from existing actor to a new one
      if (host.isAttached) {
        host.detach();
      }

      host.attach(actorId, entry.value);
    }

    logger.info('$actorId: attached');
  }

  void detach() {
    logger.fine('$actorId: detaching...');

    if (!isAttached) {
      logger.warning('detaching detached view');
      return;
    }

    for (var host in _children.values) {
      // if query run() gets interrupted by stop()
      // children will be unattached
      if (host.isAttached) {
        host.detach();
      }
    }

    _changeState(EntityQueryState.created);

    logger.info('$actorId: detached');

    actorId = null;
  }

  void stop() {
    logger.fine('$actorId: stopping...');
    _isStopped = true;

    var oldActorId = actorId;

    _changeState(EntityQueryState.stopped);

    if (isAttached) {
      detach();
    }

    for (var child in _children.values) {
      child.stop();
    }

    _children.clear();
    _watcher = null;

    // Devtool: tracking ActorViewHosts stopping
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostStopped(path: '${logger.fullName}'),
    );

    logger.info('$oldActorId: stopped');
  }

  void reportView(String viewName) {
    final wasReported = _notLoadedChildren.remove(viewName);

    // This check helps us avoid double report.
    if (!wasReported) {
      return;
    }

    logger.fine(
      'Reported view $viewName as ready. Yet to be loaded children: $_notLoadedChildren',
    );

    if (_notLoadedChildren.isEmpty) {
      _changeState(EntityQueryState.loaded);
      parent?.reportQuery(actorId!);
    }
  }

  void _changeState(EntityQueryState newState) {
    var oldState = _state;
    _state = newState;
    _watcher?.call(ActorQueryPath.state());

    logger.info('$actorId: query state changed from $oldState to $_state');
  }

  var _state = EntityQueryState.created;
  // maps view name to view host
  final _children = <String, ActorViewHost>{};
  final _notLoadedChildren = <String>{};
  ActorQueryPathFunc? _watcher;
  bool _isStopped = false;
}

/// States that an entity query can be in during its lifecycle.
///
/// - [created]: Query has been initialized but not yet executed
/// - [loaded]: Query has completed successfully and data is available
/// - [error]: Query execution failed
/// - [stopped]: Query has been terminated and cleaned up
enum EntityQueryState { created, loaded, error, stopped }

/// Interface for collecting entity views in a query.
///
/// Used by [EntityQuery.initViews] to register the views that
/// should be retrieved from entities.
abstract class EntityQueryGroup {
  void add(EntityView view);
}

/// Base class for hosting entity view data and managing real-time updates.
///
/// View hosts handle:
/// - Receiving initial data from query results
/// - Subscribing to real-time view changes
/// - Projecting changes to update local state
/// - Managing child queries for complex views
abstract class ActorViewHost {
  ActorViewHost(this.parentLoggerName, this.parent, this.view, this.system)
    : logger = Logger('$parentLoggerName.${view.name}') {
    // Devtool: tracking ActorViewHosts creation
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostCreated(path: '${logger.fullName}'),
    );
  }

  final String parentLoggerName;

  final EntityView view;

  final HordaClientSystem system;

  final Logger logger;

  final ActorQueryHost parent;

  EntityId? actorId;

  String get entityName => parent.query.entityName;

  dynamic get value => _value;

  String get changeId => _changeId;

  bool get isAttached => actorId != null;

  String get debugId {
    return '${isAttached ? actorId : "unattached"}/${view.name}';
  }

  /// id is an view's actor id or composite attribute id
  /// name is a view's name or attribute name
  /// change is a view or attribute change
  Future<dynamic> project(
    String id,
    String name,
    Change event,
    dynamic previousValue,
  );

  void watch(ActorQueryPath path, ActorQueryPathFunc cb) {
    _watcher = cb;
  }

  /// Note that on reconnect the hosts are not removed/stopped. The queries are re-run and the view hosts are re-attached.
  /// Account for that when updating [ActorQueryHost.run] and [attach] logic.
  ///
  /// Ref: [FluirSystemProviderElement._reconnectionVisitor]
  void attach(EntityId actorId, ViewQueryResult result) {
    logger.fine('${this.actorId}: attaching to $actorId...');

    final oldActorId = this.actorId;
    this.actorId = actorId;

    logger.fine('$oldActorId: actorId changed to $actorId');

    _value = view.convert(result.value);
    _changeId = result.changeId;

    logger.info('$actorId: set initial value $_value');
    logger.info('$actorId: set initial version $_changeId');

    // The latest stored version at the moment of subscription to stream of changes
    final latestStoredChangeId =
        system.latestStoredChangeIdOf(
          entityName: entityName,
          id: actorId,
          name: view.name,
        ) ??
        changeId;

    // If we were subbed to a view, then unsubbed and after a while
    // subbed again, message store won't be able to save changes due to
    // the jump between q-result change id and latest stored change id.
    // So we have to clean up old changes.
    if (ChangeId.fromString(result.changeId) >
        ChangeId.fromString(latestStoredChangeId)) {
      system.messageStore.removeChanges(
        entityName: entityName,
        id: actorId,
        name: view.name,
        upToVersion: result.changeId,
      );
    }

    _sub = system
        .changes(
          entityName: entityName,
          id: actorId,
          name: view.name,
          startAt: changeId,
        )
        .listen((event) => _project(event, latestStoredChangeId));

    logger.info('$actorId: attached');
  }

  void detach() {
    logger.fine('$actorId detaching...');

    if (!isAttached) {
      logger.warning('detaching detached view');
      return;
    }

    _sub!.cancel();
    _sub = null;
    _value = null;
    _changeId = '';
    _inbox.clear();

    logger.info('$actorId: detached');

    actorId = null;
  }

  Iterable<ActorViewSub> subscriptions();

  /// Called by sub-queries of a view. Reports that a sub-query is ready.
  /// Not all views can have sub-queries.
  ///
  /// The query is considered ready when all of it's views have received and projected remote history.
  void reportQuery(String actorId);

  /// In case of views without references:
  /// - Reports to parent [ActorQueryHost] that this [ActorViewHost] is ready.
  ///
  /// In case of views with references([EntityRefView], [EntityListView]):
  /// - Lets the view know that initial changes have been projected. [reportQuery], in this
  /// case, will be the one who reports this view as ready to it's parent [ActorQueryHost].
  ///
  /// The view is considered ready when it has received and projected remote history.
  ///
  void initialChangesProjected();

  void stop() {
    logger.fine('$actorId stopping...');

    var oldActorId = actorId;

    if (isAttached) {
      detach();
    }

    // Clean up everything related to change handlers
    _changeHandlersByType.clear();

    for (final state in _changeHandlersByState.keys) {
      // Remove this host from all states so they no longer have refer to it in dispose()
      state.removeHost(this);
    }

    _changeHandlersByState.clear();

    // Devtool: tracking ActorViewHosts stopping
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostStopped(path: '${logger.fullName}'),
    );
    logger.info('$oldActorId: stopped');
  }

  /// Adds a change handler if it's not present yet.
  ///
  /// Anonymous functions (closures) shouldn't be passed as a handler.
  /// They can't be compared, so their uniqueness can't be guaranteed.
  void addChangeHandler(Type type, dynamic handler, ChangeHandlerState state) {
    _changeHandlersByType.update(
      type,
      (value) => {...value, handler},
      ifAbsent: () => {handler},
    );
    _changeHandlersByState.update(
      state,
      (value) => {...value, handler},
      ifAbsent: () => {handler},
    );
  }

  void removeChangeHandlers(State state) {
    final handlersByState = _changeHandlersByState[state];

    if (handlersByState == null) {
      logger.warning(
        'Removing change handlers when ${state.runtimeType} has not registered any',
      );

      return;
    }

    for (final handlers in _changeHandlersByType.values) {
      // Removes handlers if present
      handlers.removeAll(handlersByState);
    }

    _changeHandlersByState.remove(state);
  }

  void _project(ChangeEnvelop env, String latestStoredChangeId) async {
    if (_isProjecting) {
      _inbox.add(env);
      logger.info('$actorId: queued $env');
      return;
    }

    _isProjecting = true;
    _inbox.add(env);

    while (_inbox.isNotEmpty) {
      final env = _inbox.removeFirst();
      logger.fine('$actorId: projecting $env...');

      if (!isAttached) {
        logger.warning('$actorId detached view is not projecting $env');
        return;
      }

      // Host must listen to only those changes which are addressed to his actor
      if (env.key != actorId) {
        logger.severe(
          '$actorId received changes which don\'t belong to him. Changes sourceId: ${env.sourceId}',
        );
        continue;
      }

      // Empty changes should only come from the server, so report view as ready.
      if (env.changes.isEmpty) {
        logger.info(
          '$actorId/${view.name} received empty change envelop from ${env.sourceId}, reporting as ready.',
        );
        // this method does nothing after it's first call
        initialChangesProjected();
        continue;
      }

      // TODO: track whether this check works correctly
      if (ChangeId.fromString(env.changeId) <= ChangeId.fromString(changeId)) {
        logger.warning(
          '$actorId: received past change envelop from: ${env.sourceId}, changeId: ${env.changeId}\n'
          'current changeId: $changeId, current value: $_value',
        );
        continue;
      }

      if (env.isOverwriting) {
        await _projectLast(env);
      } else {
        await _projectAll(env);
      }

      final isRemoteChange =
          ChangeId.fromString(env.changeId) >
          ChangeId.fromString(latestStoredChangeId);

      // Report view as ready only when projecting changes received from the server.
      if (isRemoteChange) {
        // this method does nothing after it's first call
        initialChangesProjected();

        // Execute handlers here
        // Remote change envelopes always have 1 change
        final change = env.changes.first;
        _runChangeHandlers(change);
      }

      _watcher?.call(ActorQueryPath.root(view.name));

      logger.info('$actorId: projected $env');
    }

    _isProjecting = false;
    logger.info('$actorId: inbox processed');
  }

  Future<void> _projectLast(ChangeEnvelop env) async {
    // Project last change included in ChangeEnvelop2
    final lastChange = env.changes.last;

    final nextValue = await project(env.key, env.name, lastChange, _value);

    // If host was detached while projecting, don't assign new value and clean up subs,
    // attr hosts and children hosts which were created by the cancelled projection.
    if (!isAttached) {
      logger.fine('Cancelled project.');
      detach();
      return;
    }

    _value = nextValue;

    final oldVersion = _changeId;
    _changeId = env.changeId;

    logger.info(
      '$actorId: new value "$_value", ver: from $oldVersion to $_changeId',
    );

    // Devtool: tracking change projection
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostProjected(
        path: '${logger.fullName}',
        envelope:
            'Change: $lastChange | version: from $oldVersion to ${env.changeId}',
        value: '$_value',
        // version: _changeId, // TODO: decide what too do with devtool
        version: 0,
      ),
    );
  }

  Future<void> _projectAll(ChangeEnvelop env) async {
    // Project every change included in ChangeEnvelop2
    for (final change in env.changes) {
      final nextValue = await project(env.key, env.name, change, _value);

      // If host was detached while projecting, don't assign new value and clean up subs,
      // attr hosts and children hosts which were created by the cancelled projection.
      if (!isAttached) {
        logger.fine('Skipped project.');
        detach();
        return;
      }

      _value = nextValue;

      logger.info('$actorId: new value -> $_value');
    }

    _changeId = env.changeId;
    logger.info('$actorId: new changeId -> $_changeId');

    // Devtool: tracking change projection
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostProjected(
        path: '${logger.fullName}',
        envelope: env.toString(),
        value: '$_value',
        // version: _changeId,
        version: 0,
      ),
    );
  }

  void _runChangeHandlers(Change change) {
    // Strip generic type from ValueViewChanged.
    final changeType = change is ValueViewChanged
        ? ValueViewChanged
        : change.runtimeType;

    final handlers = _changeHandlersByType[changeType];

    if (handlers == null) {
      return;
    }

    for (final h in handlers) {
      h(change);
    }
  }

  dynamic _value;
  String _changeId = ''; // what should be initial value of changeId?
  bool _isProjecting = false;
  StreamSubscription<ChangeEnvelop>? _sub;
  ActorQueryPathFunc? _watcher;
  final _inbox = Queue<ChangeEnvelop>();

  /// Key - type
  /// Value - list of change handlers for the type
  final _changeHandlersByType = <Type, Set>{};

  /// Key - state
  /// Value - list of change handlers added by the state
  final _changeHandlersByState = <ChangeHandlerState, Set>{};
}

/// Host for managing value view data and updates.
///
/// Handles simple value views that contain single typed values.
/// Receives value change events and updates the local value accordingly.
class ActorValueViewHost<T> extends ActorViewHost {
  ActorValueViewHost(
    super.parentLoggerName,
    super.parent,
    super.view,
    super.system,
  );

  @override
  Future<T?> project(
    String id,
    String name,
    Change event,
    dynamic previousValue,
  ) async {
    if (event is ValueViewChanged) {
      return event.newValue;
    }

    logger.warning('$actorId: unknown event $event');
    return previousValue;
  }

  @override
  Iterable<ActorViewSub> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    if (view.subscribe) {
      return [
        ActorViewSub(entityName, actorId!, view.name),
      ];
    } else {
      return [];
    }
  }

  @override
  void reportQuery(String actorId) {
    throw UnsupportedError(
      'ActorValueViewHost is not supposed to have sub-queries',
    );
  }

  @override
  void initialChangesProjected() {
    parent.reportView(view.name);
  }
}

/// Host for managing counter view data and updates.
///
/// Handles counter views that support increment, decrement, and reset
/// operations. Maintains the current counter value and applies changes.
class ActorCounterViewHost extends ActorViewHost {
  ActorCounterViewHost(
    super.parentLoggerName,
    super.parent,
    super.view,
    super.system,
  );

  @override
  Future<int> project(
    String id,
    String name,
    Change event,
    dynamic previousValue,
  ) async {
    if (event is CounterViewIncremented) {
      return previousValue + event.by;
    }

    if (event is CounterViewDecremented) {
      return previousValue - event.by;
    }

    if (event is CounterViewReset) {
      return event.newValue;
    }

    logger.warning('$actorId: unknown event $event');
    return previousValue;
  }

  @override
  Iterable<ActorViewSub> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    if (view.subscribe) {
      return [
        ActorViewSub(entityName, actorId!, view.name),
      ];
    } else {
      return [];
    }
  }

  @override
  void reportQuery(String actorId) {
    throw UnsupportedError(
      'ActorCounterViewHost is not supposed to have sub-queries',
    );
  }

  @override
  void initialChangesProjected() {
    parent.reportView(view.name);
  }
}

/// Host for managing reference view data and updates.
///
/// Handles reference views that point to other entities. Manages:
/// - Reference ID changes
/// - Child query execution for referenced entities
/// - Attribute management for the reference
class ActorRefViewHost extends ActorViewHost {
  ActorRefViewHost(
    super.parentLoggerName,
    super.parent,
    EntityRefView super.view,
    super.system,
  ) {
    // Initialize child in constructor body to let super() constructor run first,
    // so that the order of events for DevtoolEventLog has proper sequence.
    child = view.query.childHost(
      '$parentLoggerName.${view.name}',
      this,
      system,
    );

    _attrHost = AttributesHost(
      '$parentLoggerName.${view.name}',
      _watcher,
      view.name,
      view.attrs,
      system,
    );
  }

  late final ActorQueryHost child;

  EntityId? get refId => super.value;

  @override
  EntityRefView get view => super.view as EntityRefView;

  T valueAttr<T>(String attrName) {
    if (refId == null) {
      throw FluirError('null ref ${view.name} cannot have any attributes');
    }

    return _attrHost.valueAttr<T>(attrName);
  }

  int counterAttr(String attrName) {
    if (refId == null) {
      throw FluirError('null ref ${view.name} cannot have any attributes');
    }

    return _attrHost.counterAttr(attrName);
  }

  bool hasAttribute(String attrName) {
    return _attrHost.hasAttribute(attrName);
  }

  @override
  void watch(ActorQueryPath path, ActorQueryPathFunc cb) {
    super.watch(path.first, cb);

    if (path.next.isNotEmpty) {
      child.watch(path.next, (childPath) => cb(childPath.prepend(path.first)));
    }
  }

  @override
  void attach(EntityId actorId, covariant RefQueryResult result) {
    super.attach(actorId, result);

    if (result.value != null) {
      _attrHost.start(actorId, result.value!, result.attrs);
    }

    if (result.query != null) {
      child.attach(refId!, result.query!);
    }
  }

  @override
  void detach() {
    _alreadyReported = false;
    if (refId != null) {
      _attrHost.stop();
      child.detach();
    }
    super.detach();
  }

  @override
  void stop() {
    _attrHost.stop();
    child.stop();
    super.stop();
  }

  @override
  Future<EntityId?> project(
    String id,
    String name,
    Change event,
    dynamic previousValue,
  ) async {
    if (event is RefViewChanged) {
      if (previousValue == null && event.newValue != null) {
        _attrHost.start(id, event.newValue!);
        await child.run(event.newValue!);
      }

      if (previousValue != null && event.newValue != null) {
        _attrHost.stop();
        await child.unsubscribe();
        // TODO: while we are waiting for run() to finish
        // host has prev actorId and listens to prev actorId events
        _attrHost.start(id, event.newValue!);
        await child.run(event.newValue!);
      }

      if (previousValue != null && event.newValue == null) {
        _attrHost.stop();
        await child.unsubscribe();
        child.detach();
      }

      return event.newValue;
    }

    logger.warning('$id: unknown event $event');
    return value;
  }

  @override
  Iterable<ActorViewSub> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    final subs = <ActorViewSub>[];

    if (view.subscribe) {
      subs.add(ActorViewSub(entityName, actorId!, view.name));
    }

    if (refId != null) {
      subs.addAll(child.subscriptions());
    }

    logger.info('$actorId: got subs $subs');

    return subs;
  }

  @override
  void reportQuery(String actorId) {
    if (_alreadyReported) {
      return;
    }

    logger.fine('sub-query with actorId: $actorId reported ready.');

    parent.reportView(view.name);
    _alreadyReported = true;
  }

  /// Reports to parent [ActorQueryHost] that this [ActorRefViewHost] is ready.
  /// The RefView is considered ready when it has received and projected remote history
  /// and it's child query is ready.
  @override
  void initialChangesProjected() {
    final hasSubQuery = refId != null && view.query is! EmptyQuery;
    if (hasSubQuery || _alreadyReported) {
      // Do nothing because RefView should only report as ready when it's sub-query is ready.
      return;
    }

    logger.fine(
      'view has no sub-query, so it will report as ready right after projecting initial changes',
    );
    // Report as ready, since there's no sub-query to wait for
    parent.reportView(view.name);
    _alreadyReported = true;
  }

  var _alreadyReported = false;
  late final AttributesHost _attrHost;
}

/// Host for managing list view data and updates.
///
/// Handles list views containing multiple related entities. Manages:
/// - List item addition, removal, and reordering
/// - Child queries for each list item
/// - Attributes for individual list items
class ActorListViewHost extends ActorViewHost {
  ActorListViewHost(
    super.parentLoggerName,
    super.parent,
    super.view,
    super.system,
  );

  /// Unique page identifier for tracking pagination state.
  /// Assigned from the query result during attach.
  String _pageId = '';

  String get pageId => _pageId;

  /// Returns the list items with their XID keys and entity IDs.
  Iterable<ListItem> get items => super.value;

  @override
  EntityListView get view => super.view as EntityListView;

  T valueAttr<T>(String attrName, int index) {
    if (index < 0 || index >= items.length) {
      throw FluirError('index $index is out of bounds for ${view.name}');
    }

    final item = items.elementAt(index);
    final itemId = item.value;

    final attrHost = _attrHosts[itemId];

    if (attrHost == null) {
      throw FluirError(
        'couldn\'t find attributes host for $itemId in view ${view.name}',
      );
    }

    return attrHost.valueAttr<T>(attrName);
  }

  T valueAttrByKey<T>(String attrName, String itemKey) {
    if (itemKey.isEmpty) {
      throw FluirError('can not get value attribute by empty item key');
    }

    final index = items.toList().indexWhere(
      (item) => item.key == itemKey,
    );

    if (index == -1) {
      throw FluirError(
        'list item with key "$itemKey" not found in ${debugId}',
      );
    }

    return valueAttr<T>(attrName, index);
  }

  int counterAttr(String attrName, int index) {
    if (index < 0 || index >= items.length) {
      throw FluirError('index $index is out of bounds for ${view.name}');
    }

    final item = items.elementAt(index);
    final itemId = item.value;

    final attrHost = _attrHosts[itemId];

    if (attrHost == null) {
      throw FluirError(
        'couldn\'t find attributes host for $item in view ${view.name}',
      );
    }

    return attrHost.counterAttr(attrName);
  }

  int counterAttrByKey(String attrName, String itemKey) {
    if (itemKey.isEmpty) {
      throw FluirError('can not get value attribute by empty item key');
    }

    final index = items.toList().indexWhere(
      (item) => item.key == itemKey,
    );

    if (index == -1) {
      throw FluirError(
        'list item with key "$itemKey" not found in ${debugId}',
      );
    }

    return counterAttr(attrName, index);
  }

  ActorQueryHost itemHost(int index) {
    if (index >= items.length) {
      throw FluirError('index $index is out of bounds for $debugId');
    }

    final item = items.elementAt(index);
    final itemId = item.value;
    var host = _children[itemId];
    if (host == null) {
      throw FluirError('no item host found for $itemId for $debugId');
    }

    return host;
  }

  @override
  void watch(ActorQueryPath path, ActorQueryPathFunc cb) {
    super.watch(path, cb);

    if (path.next.isEmpty) {
      return;
    }

    // Must use toString explicitly, otherwise child will be null on web platform.
    var child = _children[path.next.first.toString()];
    if (child == null) {
      throw FluirError(
        'no host with id ${path.next} found in $actorId/${view.query.runtimeType}',
      );
    }

    child.watch(
      path.next.next,
      // Prepend "list_view_name/itemId"
      (childPath) => cb(childPath.prepend(path.first.append(path.next.first))),
    );
  }

  @override
  void attach(EntityId actorId, covariant ListQueryResult result) {
    assert(result.items.length == result.value.length);

    super.attach(actorId, result);

    _pageId = result.pageId;
    if (_pageId.isEmpty) {
      logger.warning(
        '$actorId: received empty page id from query result, list view will not project changes',
      );
    }

    if (_children.isNotEmpty) {
      logger.warning('$actorId: list is not empty on attach');

      for (var child in _children.values) {
        child.detach();
      }
      _children.clear();
    }

    if (_attrHosts.isNotEmpty) {
      logger.warning('$actorId: attr hosts map is not empty on attach');
      for (final attrHost in _attrHosts.values) {
        attrHost.stop();
      }
      _attrHosts.clear();
    }

    final attrs = result.attrs;
    for (final pair in IterableZip([result.value, result.items])) {
      final listItem = pair[0] as ListItem;
      final itemId = listItem.value;
      final result = pair[1] as QueryResult;

      final itemHost = view.query.childHost(
        '$parentLoggerName.${view.name}',
        this,
        system,
      );
      itemHost.attach(itemId, result);

      _children[itemId] = itemHost;

      final queryResAttrs = attrs[itemId];
      _attrHosts[itemId] = AttributesHost(
        parentLoggerName,
        _watcher,
        view.name,
        view.attrs,
        system,
      )..start(actorId, itemId, queryResAttrs);
    }
  }

  @override
  void detach() {
    _hasProjectedInitialChanges = false;
    _alreadyReportedToParent = false;
    for (final attrHost in _attrHosts.values) {
      attrHost.stop();
    }
    _attrHosts.clear();

    for (final child in _children.values) {
      child.detach();
    }
    _children.clear();

    super.detach();
  }

  @override
  void stop() {
    final oldActorId = actorId;

    for (final attrHost in _attrHosts.values) {
      attrHost.stop();
    }
    _attrHosts.clear();

    for (final child in _children.values) {
      child.stop();
    }
    _children.clear();

    super.stop();
    logger.info('$oldActorId: query stopped');
  }

  @override
  Future<List<ListItem>> project(
    String id,
    String name,
    Change change,
    dynamic previousValue,
  ) async {
    if (change is! ListPageChange) {
      logger.warning(
        '$id: received change which is not a list page sync $change',
      );
      return previousValue;
    }

    if (change.pageId != _pageId) {
      logger.fine(
        '$id: skipped page sync change of another page $change',
      );
      return previousValue;
    }

    if (change is ListPageItemAdded) {
      final host = ActorQueryHost(
        '$parentLoggerName.${view.name}',
        this,
        view.query,
        system,
      );
      await host.run(change.value);

      _children[change.value] = host;
      _attrHosts[change.value] = AttributesHost(
        parentLoggerName,
        _watcher,
        view.name,
        view.attrs,
        system,
      )..start(id, change.value);

      // Create ListItem from the change's key and value
      final listItem = ListItem(change.key, change.value);

      if (previousValue.isEmpty) {
        return previousValue..add(listItem);
      }

      // Use first list item key to decide if item should be appended to beginning or end of the list.
      final first = previousValue.first as ListItem;
      if (listItem.key < first.key) {
        return previousValue..insert(0, listItem);
      }

      return previousValue..add(listItem);
    }

    if (change is ListPageItemRemoved) {
      // Find the item by its key
      final item = (previousValue as List<ListItem>).firstWhereOrNull(
        (item) => item.key == change.key,
      );

      if (item == null) {
        logger.fine('skipped removing non-existent key $change');
        return previousValue;
      }

      final itemId = item.value;

      assert(() {
        return _children.containsKey(itemId) && _attrHosts.containsKey(itemId);
      }());

      final attrHost = _attrHosts.remove(itemId);
      attrHost!.stop();
      final host = _children.remove(itemId);
      await host!.unsubscribe();
      host.stop();

      // Remove the ListItem by its key
      previousValue.removeWhere((item) => item.key == change.key);
      return previousValue;
    }

    if (change is ListPageCleared) {
      if (_children.isEmpty) {
        return previousValue..clear();
      }

      for (final attrHost in _attrHosts.values) {
        attrHost.stop();
      }
      _attrHosts.clear();

      final subs = <ActorViewSub>[];
      for (final host in _children.values) {
        subs.addAll(host.subscriptions());
        host.stop();
      }

      logger.fine('unsubscribing on ListViewCleared...');

      final queryKey = '$actorId/${parent.query.name}';
      system.unsubscribeViews(queryKey, subs);

      logger.info('unsubscribed on ListViewCleared');

      _children.clear();

      return previousValue..clear();
    }

    logger.warning('$id: unknown event $change');
    return previousValue;
  }

  @override
  Iterable<ActorViewSub> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    final subs = <ActorViewSub>[];

    if (_pageId.isEmpty) {
      logger.warning('$actorId: sending unsubscribe with empty page id');
    }

    if (view.subscribe) {
      subs.add(
        ActorViewSub(entityName, actorId!, view.name, _pageId),
      );
    }

    for (final child in _children.values) {
      subs.addAll(child.subscriptions());
    }

    logger.info('$actorId: got subs $subs');

    return subs;
  }

  /// Called by sub-queries of this [ActorListViewHost].
  ///
  /// Adds sub-query's [actorId] to [_reportedChildren]. If [initialChangesProjected] has been
  /// called at least once, this method will also check if all sub-queries reported to this view.
  /// If all sub-queries reported, then this view will report as ready to it's [parent] - [ActorQueryHost].
  ///
  /// [initialChangesProjected] will always be called before the last call of [reportQuery],
  /// because sub-queries always run after an item is added when a change is projected.
  @override
  void reportQuery(String actorId) {
    if (_alreadyReportedToParent) {
      return;
    }

    _reportedChildren.add(actorId);
    logger.fine(
      'ListView received report from sub-query with actorId: $actorId',
    );

    // This if check should always be after _reportedChildren.add call
    if (!_hasProjectedInitialChanges) {
      return;
    }

    if (_reportedChildren.containsAll(_initialChildren)) {
      logger.fine(
        'all sub-queries of this ListView have reported, so it will report to it\'s parent query as ready.',
      );
      parent.reportView(view.name);
      _alreadyReportedToParent = true;
    }
  }

  /// Lets the [ActorListViewHost] know that it has initialized it's items/children and
  /// [reportQuery] can now rely on [_initialChildren] to see if all sub queries are ready.
  ///
  /// [initialChangesProjected] will always be called before the last call of [reportQuery],
  /// because sub-queries run after an item is added when a change is projected.
  @override
  void initialChangesProjected() {
    if (_hasProjectedInitialChanges || _alreadyReportedToParent) {
      return;
    }

    _initialChildren.addAll(_children.keys);
    _hasProjectedInitialChanges = true;

    final hasNoSubQueries =
        _initialChildren.isEmpty || view.query is EmptyQuery;
    if (hasNoSubQueries) {
      logger.fine(
        'ListView has projected initial changes, but has no sub-queries. It will report as ready right away.',
      );
      parent.reportView(view.name);
      _alreadyReportedToParent = true;
      return;
    }

    // It's important to have this check and call reportView in initialChangesProjected().
    // Otherwise ListView won't report ready in due time, if it's last initial change
    // didn't add an item and therefore didn't cause a sub-query to run.
    if (_reportedChildren.containsAll(_initialChildren)) {
      logger.fine(
        'all sub-queries of this ListView have reported, so it will report to it\'s parent query as ready.',
      );
      parent.reportView(view.name);
      _alreadyReportedToParent = true;
      return;
    }

    logger.fine(
      'ListView has projected initial changes. Now it waits for following sub-queries: $_initialChildren',
    );
  }

  final _initialChildren = <EntityId>{};
  final _reportedChildren = <EntityId>{};

  /// Whether <b>initial changes</b> were projected by this [ActorListViewHost].
  ///
  /// <b>Initial changes</b> are changes from remote history ChangeEnvelop2,
  /// which are received upon subscribing to a view.
  var _hasProjectedInitialChanges = false;
  var _alreadyReportedToParent = false;

  final _children = <EntityId, ActorQueryHost>{};
  final _attrHosts = <EntityId, AttributesHost>{};
}

/// Base class for inherited widgets that notify dependents of model changes.
///
/// Provides selective notification based on aspects, allowing widgets to
/// depend on specific parts of a model and only rebuild when those parts change.
abstract class InheritedModelNotifier<T> extends InheritedWidget {
  InheritedModelNotifier({super.key, required super.child});

  // TODO: move it to element class
  final aspectChanges = SetNotifier<T>();

  @protected
  bool updateShouldNotifyDependent(Set<T> changes, Set<T> dependencies);

  @override
  bool updateShouldNotify(InheritedModelNotifier<T> oldWidget) {
    return true;
  }

  @override
  InheritedElement createElement() => InheritedModelNotifierElement<T>(this);

  static T inheritFrom<T extends InheritedModelNotifier<Object>>(
    BuildContext context, {
    required Object aspect,
  }) {
    // Create a dependency on all of the type T ancestor models up until
    // a model is found for which isSupportedAspect(aspect) is true.
    final List<InheritedElement> models = <InheritedElement>[];
    _findModels<T>(context, aspect, models);
    if (models.isEmpty) {
      throw FluirError('no inherited model notifier found for $T');
    }

    final InheritedElement lastModel = models.last;
    for (final InheritedElement model in models) {
      final T value =
          context.dependOnInheritedElement(model, aspect: aspect) as T;
      if (model == lastModel) {
        return value;
      }
    }

    throw FluirError('no inherited model notifier found for $T');
  }

  static void _findModels<T extends InheritedModelNotifier<Object>>(
    BuildContext context,
    Object aspect,
    List<InheritedElement> results,
  ) {
    var model = context.getElementForInheritedWidgetOfExactType<T>();
    if (model == null) {
      return;
    }

    results.add(model);

    assert(model.widget is T);

    Element? modelParent;
    model.visitAncestorElements((Element ancestor) {
      modelParent = ancestor;
      return false;
    });
    if (modelParent == null) {
      return;
    }

    _findModels<T>(modelParent!, aspect, results);
  }
}

/// Element for the Horda system provider that handles reconnection logic.
///
/// Manages reconnection events and ensures that all query providers
/// are properly restarted when the connection is reestablished.
class FluirSystemProviderElement
    extends InheritedModelNotifierElement<HordaModelAspect> {
  FluirSystemProviderElement(HordaSystemProvider widget)
    : conn = widget.system.conn,
      super(widget) {
    conn.addListener(_onReconnect);
  }

  final Connection conn;

  @override
  void unmount() {
    conn.removeListener(_onReconnect);
    super.unmount();
  }

  void _onReconnect() {
    if (conn.value is ConnectionStateReconnected) {
      visitChildElements(_reconnectionVisitor);
    }
  }

  void _reconnectionVisitor(Element element) {
    if (element is ActorQueryProviderElement) {
      element.host.unsubscribe();
      element.host.detach();
      element.host.run(element.actorId);
      return;
    }
    element.visitChildElements(_reconnectionVisitor);
  }
}

/// Element implementation for [InheritedModelNotifier] widgets.
///
/// Handles dependency tracking and selective notification based on
/// model aspects that widgets depend on.
class InheritedModelNotifierElement<T> extends InheritedElement {
  InheritedModelNotifierElement(InheritedModelNotifier<T> widget)
    : super(widget) {
    widget.aspectChanges.addListener(_handleUpdate);
  }

  // notifier overrides

  @override
  void update(InheritedModelNotifier<T> newWidget) {
    final oldChanges = (widget as InheritedModelNotifier<T>).aspectChanges;
    final newChanges = newWidget.aspectChanges;
    if (oldChanges != newChanges) {
      oldChanges.removeListener(_handleUpdate);
      newChanges.addListener(_handleUpdate);
    }
    super.update(newWidget);
  }

  @override
  Widget build() {
    if (_dirty) {
      notifyClients(widget as InheritedModelNotifier<T>);
    }
    return super.build();
  }

  @override
  void notifyClients(InheritedModelNotifier<T> oldWidget) {
    super.notifyClients(oldWidget);
    (widget as InheritedModelNotifier<T>).aspectChanges.clear();
    _dirty = false;
  }

  @override
  void unmount() {
    var model = widget as InheritedModelNotifier<T>;
    model.aspectChanges.removeListener(_handleUpdate);
    super.unmount();
  }

  void _handleUpdate() {
    _dirty = true;
    markNeedsBuild();
  }

  // model overrides

  @override
  void updateDependencies(Element dependent, Object? aspect) {
    var dependencies = getDependencies(dependent) as Set<T>?;
    if (dependencies != null && dependencies.isEmpty) {
      return;
    }

    if (aspect == null) {
      setDependencies(dependent, HashSet<T>());
      return;
    }

    assert(aspect is T);
    setDependencies(
      dependent,
      (dependencies ?? HashSet<T>())..add(aspect as T),
    );
  }

  @override
  void notifyDependent(InheritedModelNotifier<T> oldWidget, Element dependent) {
    var dependencies = getDependencies(dependent) as Set<T>?;
    if (dependencies == null) {
      return;
    }

    if (dependencies.isEmpty) {
      dependent.didChangeDependencies();
    }

    var w = widget as InheritedModelNotifier<T>;
    if (w.updateShouldNotifyDependent(
      oldWidget.aspectChanges.set,
      dependencies,
    )) {
      dependent.didChangeDependencies();
    }
  }

  bool _dirty = false;
}

/// Element for entity query providers that manages query lifecycle.
///
/// Handles query execution, dependency tracking, and cleanup when
/// the provider is unmounted.
class ActorQueryProviderElement
    extends InheritedModelNotifierElement<ActorQueryPath> {
  ActorQueryProviderElement(super.widget, this.query, HordaClientSystem system)
    : host = query.rootHost('Query', system) {
    actorId = provider.entityId;

    logger = Logger('Query.${query.name}');
    logger.info('$actorId: provider created');
  }

  final EntityQuery query;

  final ActorQueryHost host;

  late final Logger logger;

  late final EntityId actorId;

  EntityQueryProvider get provider => widget as EntityQueryProvider;

  @override
  void mount(Element? parent, Object? newSlot) {
    logger.fine('$actorId: provider mounting...');
    super.mount(parent, newSlot);

    host.run(actorId);

    logger.info('$actorId: provider mounted');
  }

  @override
  void unmount() {
    logger.fine('$actorId: provider unmounting...');

    host.unsubscribe();
    host.stop();
    _unmounted = true;

    super.unmount();
    logger.info('$actorId: provider unmounted');
  }

  void depend(Type parentQuery, ActorQueryPath path, BuildContext context) {
    assert(!_unmounted);

    context.dependOnInheritedElement(this, aspect: path);
    host.watch(path, (p) {
      if (!mounted) {
        return;
      }
      provider.aspectChanges.add(p);
    });
  }

  bool _unmounted = false;
}

/// Function type for handling query path changes.
///
/// Used internally for notifying widgets when specific query paths change.
typedef ActorQueryPathFunc = void Function(ActorQueryPath path);

/// Provider widget that runs entity queries and provides results to child widgets.
///
/// Manages the execution of entity queries and provides reactive access to
/// query results. Child widgets can access query data using `context.query<T>()`
/// and will automatically rebuild when the data changes.
///
/// Example:
/// ```dart
/// EntityQueryProvider(
///   entityId: 'user-123',
///   query: UserQuery(),
///   child: UserWidget(),
/// )
/// ```
class EntityQueryProvider extends InheritedModelNotifier<ActorQueryPath> {
  EntityQueryProvider({
    required this.entityId,
    required this.query,
    required this.system,
    required super.child,
  }) : super(key: ValueKey('$entityId/${query.runtimeType}'));

  final EntityId entityId;

  final EntityQuery query;

  final HordaClientSystem system;

  @override
  InheritedElement createElement() {
    return ActorQueryProviderElement(this, query, system);
  }

  @override
  bool updateShouldNotifyDependent(
    Set<ActorQueryPath> changes,
    Set<ActorQueryPath> dependencies,
  ) {
    for (var change in changes) {
      if (dependencies.firstWhereOrNull((d) => d.match(change)) != null) {
        return true;
      }
    }
    return false;
  }

  static ActorQueryProviderElement find<T extends EntityQuery>(
    BuildContext context,
  ) {
    ActorQueryProviderElement? found;

    context.visitAncestorElements((element) {
      if (element is ActorQueryProviderElement) {
        if (element.query is T) {
          found = element;
          return false;
        }
      }
      return true;
    });

    if (found == null) {
      throw FluirError('no ActorQueryProviderElement found for $T');
    }

    return found!;
  }
}

extension ActorQueryProviderName on ActorQueryHost {
  ValueKey<String> get key => ValueKey('$actorId/${query.name}');
}

/// Notifier that tracks a set of items and notifies listeners when items are added.
///
/// Used internally for tracking changes to query aspects and notifying
/// dependent widgets when specific aspects change.
class SetNotifier<T> extends ChangeNotifier {
  Set<T> get set => Set<T>.unmodifiable(_set);

  void add(T item) {
    _set.add(item);
    notifyListeners();
  }

  void clear() {
    _set.clear();
  }

  final _set = HashSet<T>();
}

/// Represents a path to a specific view or state within an entity query.
///
/// Query paths are used for dependency tracking, allowing widgets to
/// depend on specific parts of query results and rebuild only when
/// those specific parts change.
class ActorQueryPath {
  ActorQueryPath._(List<String> views) : _views = views;

  ActorQueryPath.empty() : _views = [];

  ActorQueryPath.root(String viewName) : _views = [viewName];

  ActorQueryPath.state() : _views = ['state'];

  ActorQueryPath get first => ActorQueryPath.root(_views.first);

  ActorQueryPath get next {
    if (_views.isEmpty) {
      return this;
    }

    return ActorQueryPath._(_views.skip(1).toList());
  }

  bool get isEmpty => !isNotEmpty;

  bool get isNotEmpty => _views.isNotEmpty;

  bool get isState => _views.length == 1 && _views[0] == 'state';

  ActorQueryPath append(ActorQueryPath path) {
    var vx = [..._views, ...path._views];
    return ActorQueryPath._(vx);
  }

  ActorQueryPath prepend(ActorQueryPath path) {
    var vx = [...path._views, ..._views];
    return ActorQueryPath._(vx);
  }

  bool match(ActorQueryPath change) {
    return toString().startsWith(change.toString());
  }

  @override
  String toString() => _views.join('/');

  @override
  int get hashCode => toString().hashCode;

  @override
  bool operator ==(Object other) {
    return toString() == other.toString();
  }

  final List<String> _views;
}

/// Host for managing entity reference and list item attributes.
///
/// Handles attribute data for references and list items, including:
/// - Subscribing to attribute changes
/// - Projecting attribute updates
/// - Managing attribute lifecycle
class AttributesHost {
  AttributesHost(
    this.parentLoggerName,
    ActorQueryPathFunc? watcher,
    this.viewName,
    this.viewAttrs,
    this.system,
  ) : _watcher = watcher,
      logger = Logger('$parentLoggerName.AttributesHost');

  final String parentLoggerName;
  final String viewName;
  final List<String> viewAttrs;
  final HordaClientSystem system;
  final Logger logger;

  /// Since collisions with entityId1-entityId2/attrName key format are unlikely,
  /// entity name is empty for attributes and their changes.
  String get entityName => '';

  /// Id of type [String] produced by combining id of two actors via [CompositeId]
  EntityId? id;

  bool get isAttached => id != null;

  String get debugId => '$viewName/$id';

  void start(
    EntityId viewActorId,
    EntityId valueActorId, [
    Map<String, dynamic>? queryResAttrs,
  ]) {
    id = CompositeId(viewActorId, valueActorId).id;

    logger.fine('starting attrHost $debugId...');
    // Sub to attribute change streams
    attach(queryResAttrs);
    // Request Sub to attribute changes from server
    subscribe();

    logger.fine('started attrHost $id');
  }

  void stop() {
    logger.fine('stopping attrHost $debugId...');

    // Request Unsub from changes
    unsubscribe();

    // close streams, clean up.
    final oldDebugId = debugId;
    detach();

    logger.fine('stopped attrHost $oldDebugId');
  }

  void attach([Map<String, dynamic>? queryResAttrs]) {
    logger.fine('attaching attrHost $debugId...');

    // Query result won't be null only on initial RefView/ListView attach
    // in all other cases _attrs will be empty
    if (queryResAttrs != null) {
      for (final MapEntry(key: name, value: attr) in queryResAttrs.entries) {
        _attrs[name] = {
          // 'val' and 'chid' keys are based on ViewSnapshot.toJson()
          'value': attr['val'],
          'version': attr['chid'],
        };
      }
    }

    // Sub for changes
    for (final name in viewAttrs) {
      _attrs[name] ??= <String, dynamic>{
        'value': null,
        'version': '', // empty string is initial changeId for view hosts
      };
      final Map<String, dynamic> attr = _attrs[name];

      _subs[name] = system
          .changes(entityName: entityName, id: id!, name: name)
          .listen((e) => _project(name, attr, e));
    }

    logger.fine('attached attrHost $debugId');
  }

  void detach() {
    logger.fine('stopping attrHost $debugId...');

    for (final sub in _subs.values) {
      sub.cancel();
    }
    _subs.clear();
    _attrs.clear();

    final oldDebugId = debugId;
    id = null;

    logger.fine('stopped attrHost $oldDebugId');
  }

  Iterable<ActorViewSub> subscriptions() {
    final viewSubs = <ActorViewSub>[];

    for (final MapEntry(key: name) in _attrs.entries) {
      viewSubs.add(ActorViewSub.attr(id!, name));
    }

    return viewSubs;
  }

  Future<void> subscribe() async {
    logger.fine('subscribing attrHost $debugId...');
    await system.subscribeViews(subscriptions());
    logger.fine('subscribed attrHost $debugId');
  }

  Future<void> unsubscribe() async {
    logger.fine('unsubscribing attrHost $debugId...');
    // No query key for AttributesHost
    await system.unsubscribeViews('', subscriptions());
    logger.fine('unsubscribed attrHost $debugId');
  }

  bool hasAttribute(String attrName) {
    final attr = _attrs[attrName];
    return attr != null && attr.isNotEmpty;
  }

  T valueAttr<T>(String attrName) {
    final attr = _attrs[attrName];

    if (attr == null) {
      throw FluirError(
        'no value attribute $id/$attrName found in view $viewName',
      );
    }

    final attrValue = attr['value'];

    if (attrValue is! T) {
      throw FluirError(
        'view $viewName value attribute $id/$attrName type ${attrValue.runtimeType} does not match expect type $T',
      );
    }

    return attrValue;
  }

  int counterAttr(String attrName) {
    final attr = _attrs[attrName];

    if (attr == null) {
      throw FluirError(
        'no counter attribute $id/$attrName found in view $viewName',
      );
    }

    final attrValue = attr['value'];

    if (attrValue is! int) {
      throw FluirError(
        'view $viewName counter attribute $id/$attrName type ${attrValue.runtimeType} does not match expect type int',
      );
    }

    return attrValue;
  }

  void _project(String name, Map<String, dynamic> attr, ChangeEnvelop env) {
    logger.fine('$debugId: projecting $env...');

    if (!isAttached) {
      logger.warning('$debugId detached attribute is not projecting $env');
      return;
    }

    // Host must listen to only those changes which are addressed to his actor
    if (env.key != id || env.name != name) {
      logger.severe(
        '$debugId received changes which don\'t belong to him. Changes sourceId: ${env.sourceId}',
      );
      return;
    }

    if (env.changes.isEmpty) {
      logger.info(
        '$debugId received empty change envelop from ${env.sourceId}.',
      );
      return;
    }

    // Create attribute with first projected change
    if (attr.isEmpty) {
      logger.info('$debugId: creating an attribute with $env');
      if (env.isOverwriting) {
        _projectLast(name, attr, env);
      } else {
        _projectAll(name, attr, env);
      }

      _attrs[name] = attr;

      _watcher?.call(ActorQueryPath.root(viewName));

      logger.info('$debugId: projected $env');
      return;
    }

    final currentChId = attr['version'] as String;
    final currentVal = attr['value'];

    // TODO: track whether this version check works correctly
    if (ChangeId.fromString(env.changeId) <= ChangeId.fromString(currentChId)) {
      logger.info(
        '$debugId: ignored past change envelop from: ${env.sourceId}, changeId: ${env.changeId}\n'
        'current version: $currentChId, current value: $currentVal',
      );
      return;
    }

    if (env.isOverwriting) {
      _projectLast(name, attr, env);
    } else {
      _projectAll(name, attr, env);
    }

    _watcher?.call(ActorQueryPath.root(viewName));

    logger.info('$debugId: projected $env');
  }

  Future<void> _projectLast(
    String name,
    Map<String, dynamic> attr,
    ChangeEnvelop env,
  ) async {
    final lastChange = env.changes.last;
    final wasCreated = attr.isEmpty;
    final oldVersion = attr['version'] as String?;

    attr['value'] = _getProjectedValue(attr, lastChange);
    attr['version'] = env.changeId;

    if (wasCreated) {
      logger.info(
        '$debugId: created $name with value "${attr['value']}", ver: ${attr['version']}',
      );
      return;
    }

    logger.info(
      '$debugId: new value "${attr['value']}", ver: from $oldVersion to ${attr['version']}',
    );
  }

  Future<void> _projectAll(
    String name,
    Map<String, dynamic> attr,
    ChangeEnvelop env,
  ) async {
    for (final change in env.changes) {
      if (attr.isEmpty) {
        attr['value'] = _getProjectedValue(attr, change);
        logger.info('$debugId: created $name with value -> ${attr['value']}');
        continue;
      }

      attr['value'] = _getProjectedValue(attr, change);
      logger.info('$debugId: new value -> ${attr['value']}');
    }

    attr['version'] = env.changeId;
    logger.info('$debugId: new ver -> ${attr['version']}');
  }

  dynamic _getProjectedValue(Map<String, dynamic> attr, Change change) {
    return switch (change) {
      RefValueAttributeChanged() => _onRefValueAttributeChanged(attr, change),
      CounterAttrIncremented() => _onCounterAttrIncremented(attr, change),
      CounterAttrDecremented() => _onCounterAttrDecremented(attr, change),
      CounterAttrReset() => _onCounterAttrReset(attr, change),
      _ => throw FluirError(
        'Unsupported attribute change type - ${change.runtimeType}.',
      ),
    };
  }

  dynamic _onRefValueAttributeChanged(
    Map<String, dynamic> attr,
    RefValueAttributeChanged change,
  ) {
    return change.newValue;
  }

  dynamic _onCounterAttrIncremented(
    Map<String, dynamic> attr,
    CounterAttrIncremented change,
  ) {
    return (attr['value'] ?? 0) + change.by;
  }

  dynamic _onCounterAttrDecremented(
    Map<String, dynamic> attr,
    CounterAttrDecremented change,
  ) {
    return (attr['value'] ?? 0) - change.by;
  }

  dynamic _onCounterAttrReset(
    Map<String, dynamic> attr,
    CounterAttrReset change,
  ) {
    return change.newValue;
  }

  /// Key is attribute name
  /// Value is [Map] with attribute's value and version
  final _attrs = <String, dynamic>{};

  /// Key is attribute name
  /// Value is the subscription to attribute's changes
  final _subs = <String, StreamSubscription<ChangeEnvelop>>{};

  ActorQueryPathFunc? _watcher;
}
