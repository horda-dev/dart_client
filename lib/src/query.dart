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

abstract class ActorQuery implements ActorQueryGroup {
  ActorQuery() {
    initViews(this);
  }

  String get name => '$runtimeType';

  Map<String, ActorView> get views => _views;

  @override
  void add(ActorView view) {
    _views[view.name] = view;
  }

  QueryDefBuilder queryBuilder() {
    var qb = QueryDefBuilder();

    for (var v in _views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  void initViews(ActorQueryGroup views);

  ActorQueryHost rootHost(String parentLoggerName, FluirClientSystem system) {
    return ActorQueryHost(parentLoggerName, null, this, system);
  }

  ActorQueryHost childHost(
    String parentLoggerName,
    ActorViewHost parent,
    FluirClientSystem system,
  ) {
    return ActorQueryHost(parentLoggerName, parent, this, system);
  }

  final _views = <String, ActorView>{};
}

class EmptyQuery extends ActorQuery {
  @override
  void initViews(ActorQueryGroup views) {}
}

typedef ViewConvertFunc = dynamic Function(dynamic val);

dynamic _identity(dynamic val) => val;

abstract class ActorView {
  ActorView(
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
    FluirClientSystem system,
  );
}

typedef ValueViewConvertFunc<T> = T? Function(dynamic val);

class ActorValueView<T> extends ActorView {
  ActorValueView(
    super.name, {
    super.subscribe,
    ValueViewConvertFunc<T>? convert,
  }) : super(
          convert: convert ?? (val) => _defaultValueConvert<T>(name, val),
          nullable: null is T,
        );

  @override
  ViewQueryDefBuilder queryBuilder() {
    return ValueQueryDefBuilder(
      name,
      subscribe: subscribe,
    );
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    FluirClientSystem system,
  ) {
    return ActorValueViewHost<T>(
      parentLoggerName,
      parent,
      this,
      system,
    );
  }
}

T _defaultValueConvert<T>(String viewName, dynamic val) {
  if (val is! T) {
    throw FluirError(
      'view $viewName value type is invalid $val',
    );
  }
  return val;
}

class ActorDateTimeView extends ActorValueView<DateTime> {
  ActorDateTimeView(
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

  return DateTime.fromMillisecondsSinceEpoch(
    val,
    isUtc: isUtc,
  );
}

class ActorCounterView<T> extends ActorView {
  ActorCounterView(
    super.name, {
    super.subscribe,
    super.nullable,
  });

  @override
  ViewQueryDefBuilder queryBuilder() {
    return ValueQueryDefBuilder(
      name,
      subscribe: subscribe,
    );
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    FluirClientSystem system,
  ) {
    return ActorCounterViewHost(
      parentLoggerName,
      parent,
      this,
      system,
    );
  }
}

class ActorRefView<S extends ActorQuery> extends ActorView {
  ActorRefView(
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
    var qb = RefQueryDefBuilder(name, attrs);

    for (var v in query.views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    FluirClientSystem system,
  ) {
    return ActorRefViewHost(
      parentLoggerName,
      parent,
      this,
      system,
    );
  }
}

class ActorListView<S extends ActorQuery> extends ActorView {
  ActorListView(
    String name, {
    super.subscribe,
    required this.query,
    this.attrs = const [],
  }) : super(name, convert: (res) => List<ActorId>.from(res));
  // above we are creating a mutable list from immutable list coming from json

  final S query;

  final List<String> attrs;

  @override
  ViewQueryDefBuilder queryBuilder() {
    var qb = ListQueryDefBuilder(name, attrs);

    for (var v in query.views.values) {
      qb.add(v.queryBuilder());
    }

    return qb;
  }

  @override
  ActorViewHost childHost(
    String parentLoggerName,
    ActorQueryHost parent,
    FluirClientSystem system,
  ) {
    return ActorListViewHost(
      parentLoggerName,
      parent,
      this,
      system,
    );
  }
}

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
      DevtoolFluirHostCreated(
        path: '${logger.fullName}',
      ),
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

  final ActorQuery query;

  final FluirClientSystem system;

  late final Logger logger;

  ActorViewHost? parent;

  ActorId? actorId;

  ActorQueryState get state => _state;

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

    var first = path.first;
    var child = children[first];

    if (child == null) {
      throw FluirError('no view host found for query path $path');
    }

    child.watch(path, cb);
  }

  Future<void> run(ActorId actorId) async {
    final qdef = query.queryBuilder().build();

    logger.fine('$actorId: running query...');
    logger.finer('$actorId: running query: ${qdef.toJson()}');

    this.actorId = actorId;

    try {
      final res = await system.query(
        actorId: actorId,
        name: query.name,
        def: qdef,
      );

      logger.finer('$actorId: got query result: ${res.toJson()}');

      if (_isStopped) {
        logger.info('$actorId: run stopped');
        return;
      }

      attach(actorId, res);

      await subscribe();

      logger.info('$actorId: ran');
    } catch (e) {
      _changeState(ActorQueryState.error);

      logger.severe('$actorId: query ran with error: $e');
    }
  }

  Future<void> subscribe() async {
    logger.fine('$actorId: subscribing...');

    await system.subscribeViews(subscriptions());

    logger.info('$actorId: subscribed');
  }

  Future<void> unsubscribe() async {
    logger.fine('$actorId: unsubscribing...');

    await system.unsubscribeViews(subscriptions());

    logger.info('$actorId: unsubscribed');
  }

  Iterable<ActorViewSub2> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached query');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    var subs = <ActorViewSub2>[];

    for (var child in _children.values) {
      subs.addAll(child.subscriptions());
    }

    logger.info('$actorId: got subs for $subs');

    return subs;
  }

  void attach(ActorId actorId, QueryResult2 result) {
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

    _changeState(ActorQueryState.created);

    logger.info('$actorId: detached');

    actorId = null;
  }

  void stop() {
    logger.fine('$actorId: stopping...');
    _isStopped = true;

    var oldActorId = actorId;

    _changeState(ActorQueryState.stopped);

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
      DevtoolFluirHostStopped(
        path: '${logger.fullName}',
      ),
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
      _changeState(ActorQueryState.loaded);
      parent?.reportQuery(actorId!);
    }
  }

  void _changeState(ActorQueryState newState) {
    var oldState = _state;
    _state = newState;
    _watcher?.call(ActorQueryPath.state());

    logger.info('$actorId: query state changed from $oldState to $_state');
  }

  var _state = ActorQueryState.created;
  // maps view name to view host
  final _children = <String, ActorViewHost>{};
  final _notLoadedChildren = <String>{};
  ActorQueryPathFunc? _watcher;
  bool _isStopped = false;
}

enum ActorQueryState {
  created,
  loaded,
  error,
  stopped,
}

abstract class ActorQueryGroup {
  void add(ActorView view);
}

abstract class ActorViewHost {
  ActorViewHost(
    this.parentLoggerName,
    this.parent,
    this.view,
    this.system,
  ) : logger = Logger('$parentLoggerName.${view.name}') {
    // Devtool: tracking ActorViewHosts creation
    DevtoolEventLog.sendToDevtool(
      DevtoolFluirHostCreated(
        path: '${logger.fullName}',
      ),
    );
  }

  final String parentLoggerName;

  final ActorView view;

  final FluirClientSystem system;

  final Logger logger;

  final ActorQueryHost parent;

  ActorId? actorId;

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

  void attach(ActorId actorId, ViewQueryResult2 result) {
    logger.fine('${this.actorId}: attaching to $actorId...');

    final oldActorId = this.actorId;
    this.actorId = actorId;

    logger.fine('$oldActorId: actorId changed to $actorId');

    _value = view.convert(result.value);
    _changeId = result.changeId;

    logger.info('$actorId: set initial value $_value');
    logger.info('$actorId: set initial version $_changeId');

    // The latest stored version at the moment of subscription to stream of changes
    final latestStoredChangeId = system.latestStoredChangeIdOf(
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
        id: actorId,
        name: view.name,
        upToVersion: result.changeId,
      );
    }

    _sub = system
        .changes(
          id: actorId,
          name: view.name,
          startAt: changeId,
        )
        .listen(
          (event) => _project(event, latestStoredChangeId),
        );

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

  Iterable<ActorViewSub2> subscriptions();

  /// Called by sub-queries of a view. Reports that a sub-query is ready.
  /// Not all views can have sub-queries.
  ///
  /// The query is considered ready when all of it's views have received and projected remote history.
  void reportQuery(String actorId);

  /// In case of views without references:
  /// - Reports to parent [ActorQueryHost] that this [ActorViewHost] is ready.
  ///
  /// In case of views with references([ActorRefView], [ActorListView]):
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
      DevtoolFluirHostStopped(
        path: '${logger.fullName}',
      ),
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

  void _project(ChangeEnvelop2 env, String latestStoredChangeId) async {
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

      final isRemoteChange = ChangeId.fromString(env.changeId) >
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

      _watcher?.call(
        ActorQueryPath.root(view.name),
      );

      logger.info('$actorId: projected $env');
    }

    _isProjecting = false;
    logger.info('$actorId: inbox processed');
  }

  Future<void> _projectLast(ChangeEnvelop2 env) async {
    // Project last change included in ChangeEnvelop2
    final lastChange = env.changes.last;

    final nextValue = await project(
      env.key,
      env.name,
      lastChange,
      _value,
    );

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

  Future<void> _projectAll(ChangeEnvelop2 env) async {
    // Project every change included in ChangeEnvelop2
    for (final change in env.changes) {
      final nextValue = await project(
        env.key,
        env.name,
        change,
        _value,
      );

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
    final changeType =
        change is ValueViewChanged ? ValueViewChanged : change.runtimeType;

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
  StreamSubscription<ChangeEnvelop2>? _sub;
  ActorQueryPathFunc? _watcher;
  final _inbox = Queue<ChangeEnvelop2>();

  /// Key - type
  /// Value - list of change handlers for the type
  final _changeHandlersByType = <Type, Set>{};

  /// Key - state
  /// Value - list of change handlers added by the state
  final _changeHandlersByState = <ChangeHandlerState, Set>{};
}

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
  Iterable<ActorViewSub2> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    if (view.subscribe) {
      final latestChangeId = system.latestStoredChangeIdOf(
            id: actorId!,
            name: view.name,
          ) ??
          changeId;
      return [
        ActorViewSub2(actorId!, view.name, latestChangeId),
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
  Iterable<ActorViewSub2> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    if (view.subscribe) {
      final latestChangeId = system.latestStoredChangeIdOf(
            id: actorId!,
            name: view.name,
          ) ??
          changeId;
      return [
        ActorViewSub2(actorId!, view.name, latestChangeId),
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

class ActorRefViewHost extends ActorViewHost {
  ActorRefViewHost(
    super.parentLoggerName,
    super.parent,
    ActorRefView super.view,
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

  ActorId? get refId => super.value;

  @override
  ActorRefView get view => super.view as ActorRefView;

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
      child.watch(
        path.next,
        (childPath) => cb(childPath.prepend(path.first)),
      );
    }
  }

  @override
  void attach(ActorId actorId, covariant RefQueryResult2 result) {
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
  Future<ActorId?> project(
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
  Iterable<ActorViewSub2> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    final subs = <ActorViewSub2>[];

    if (view.subscribe) {
      final latestChangeId = system.latestStoredChangeIdOf(
            id: actorId!,
            name: view.name,
          ) ??
          changeId;
      subs.add(ActorViewSub2(actorId!, view.name, latestChangeId));
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

class ActorListViewHost extends ActorViewHost {
  ActorListViewHost(
    super.parentLoggerName,
    super.parent,
    super.view,
    super.system,
  );

  Iterable<ActorId> get items => super.value;

  @override
  ActorListView get view => super.view as ActorListView;

  T valueAttr<T>(String attrName, int index) {
    if (index >= items.length) {
      throw FluirError('index $index is out of bounds for ${view.name}');
    }

    final itemId = items.elementAt(index);

    final attrHost = _attrHosts[itemId];

    if (attrHost == null) {
      throw FluirError(
        'couldn\'t find attributes host for $itemId in view ${view.name}',
      );
    }

    return attrHost.valueAttr<T>(attrName);
  }

  int counterAttr(String attrName, int index) {
    if (index >= items.length) {
      throw FluirError('index $index is out of bounds for ${view.name}');
    }

    final itemId = items.elementAt(index);

    final attrHost = _attrHosts[itemId];

    if (attrHost == null) {
      throw FluirError(
        'couldn\'t find attributes host for $itemId in view ${view.name}',
      );
    }

    return attrHost.counterAttr(attrName);
  }

  ActorQueryHost itemHost(int index) {
    if (index >= items.length) {
      throw FluirError('index $index is out of bounds for $debugId');
    }

    var itemId = items.elementAt(index);
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

    var child = _children[path.next.first];
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
  void attach(ActorId actorId, covariant ListQueryResult2 result) {
    assert(result.items.length == result.value.length);

    super.attach(actorId, result);

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
      final itemId = pair[0] as ActorId;
      final result = pair[1] as QueryResult2;

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
  Future<List<ActorId>> project(
    String id,
    String name,
    Change event,
    dynamic previousValue,
  ) async {
    if (event is ListViewItemAdded) {
      final host = ActorQueryHost(
        '$parentLoggerName.${view.name}',
        this,
        view.query,
        system,
      );
      await host.run(event.itemId);

      _children[event.itemId] = host;
      _attrHosts[event.itemId] = AttributesHost(
        parentLoggerName,
        _watcher,
        view.name,
        view.attrs,
        system,
      )..start(id, event.itemId);

      return previousValue..add(event.itemId);
    }

    if (event is ListViewItemAddedIfAbsent) {
      if (!previousValue.contains(event.itemId)) {
        final host = ActorQueryHost(
          '$parentLoggerName.${view.name}',
          this,
          view.query,
          system,
        );
        await host.run(event.itemId);
        _children[event.itemId] = host;
        _attrHosts[event.itemId] = AttributesHost(
          parentLoggerName,
          _watcher,
          view.name,
          view.attrs,
          system,
        )..start(id, event.itemId);

        previousValue.add(event.itemId);
      }
      return previousValue;
    }

    if (event is ListViewItemRemoved) {
      assert(() {
        return _children.containsKey(event.itemId) &&
            _attrHosts.containsKey(event.itemId);
      }());

      final attrHost = _attrHosts.remove(event.itemId);
      attrHost!.stop();
      final host = _children.remove(event.itemId);
      await host!.unsubscribe();
      host.stop();

      return previousValue..remove(event.itemId);
    }

    if (event is ListViewCleared) {
      if (_children.isEmpty) {
        return previousValue..clear();
      }

      for (final attrHost in _attrHosts.values) {
        attrHost.stop();
      }
      _attrHosts.clear();

      final subs = <ActorViewSub2>[];
      for (final host in _children.values) {
        subs.addAll(host.subscriptions());
        host.stop();
      }

      logger.fine('unsubscribing on ListViewCleared...');
      system.unsubscribeViews(subs);
      logger.info('unsubscribed on ListViewCleared');

      _children.clear();

      return previousValue..clear();
    }

    logger.warning('$id: unknown event $event');
    return previousValue;
  }

  @override
  Iterable<ActorViewSub2> subscriptions() {
    if (actorId == null) {
      logger.warning('getting subs for detached view');
      return [];
    }

    logger.fine('$actorId: getting subs...');

    final subs = <ActorViewSub2>[];

    if (view.subscribe) {
      final latestChangeId = system.latestStoredChangeIdOf(
            id: actorId!,
            name: view.name,
          ) ??
          changeId;
      subs.add(ActorViewSub2(actorId!, view.name, latestChangeId));
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

  final _initialChildren = <ActorId>{};
  final _reportedChildren = <ActorId>{};

  /// Whether <b>initial changes</b> were projected by this [ActorListViewHost].
  ///
  /// <b>Initial changes</b> are changes from remote history ChangeEnvelop2,
  /// which are received upon subscribing to a view.
  var _hasProjectedInitialChanges = false;
  var _alreadyReportedToParent = false;

  final _children = <ActorId, ActorQueryHost>{};
  final _attrHosts = <ActorId, AttributesHost>{};
}

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

class FluirSystemProviderElement
    extends InheritedModelNotifierElement<FluirModelAspect> {
  FluirSystemProviderElement(FluirSystemProvider widget)
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

class ActorQueryProviderElement
    extends InheritedModelNotifierElement<ActorQueryPath> {
  ActorQueryProviderElement(super.widget, this.query, FluirClientSystem system)
      : host = query.rootHost('Query', system) {
    actorId = provider.actorId;

    logger = Logger('Query.${query.name}');
    logger.info('$actorId: provider created');
  }

  final ActorQuery query;

  final ActorQueryHost host;

  late final Logger logger;

  late final ActorId actorId;

  ActorQueryProvider get provider => widget as ActorQueryProvider;

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

typedef ActorQueryPathFunc = void Function(ActorQueryPath path);

class ActorQueryProvider extends InheritedModelNotifier<ActorQueryPath> {
  ActorQueryProvider({
    required this.actorId,
    required this.query,
    required this.system,
    required super.child,
  }) : super(key: ValueKey('$actorId/${query.runtimeType}'));

  final ActorId actorId;

  final ActorQuery query;

  final FluirClientSystem system;

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

  static ActorQueryProviderElement find<T extends ActorQuery>(
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

class AttributesHost {
  AttributesHost(
    this.parentLoggerName,
    ActorQueryPathFunc? watcher,
    this.viewName,
    this.viewAttrs,
    this.system,
  )   : _watcher = watcher,
        logger = Logger('$parentLoggerName.AttributesHost');

  final String parentLoggerName;
  final String viewName;
  final List<String> viewAttrs;
  final FluirClientSystem system;
  final Logger logger;

  /// Id of type [String] produced by combining id of two actors via [CompositeId]
  ActorId? id;

  bool get isAttached => id != null;

  String get debugId => '$viewName/$id';

  void start(
    ActorId viewActorId,
    ActorId valueActorId, [
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

      _subs[name] = system.changes(id: id!, name: name).listen((e) {
        _project(name, attr, e);
      });
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

  Iterable<ActorViewSub2> subscriptions() {
    final viewSubs = <ActorViewSub2>[];

    for (final MapEntry(key: name, value: attr) in _attrs.entries) {
      final latestChangeId = system.latestStoredChangeIdOf(
            id: id!,
            name: viewName,
          ) ??
          attr['version'] as String;
      viewSubs.add(ActorViewSub2(id!, name, latestChangeId));
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
    await system.unsubscribeViews(subscriptions());
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

  void _project(String name, Map<String, dynamic> attr, ChangeEnvelop2 env) {
    logger.fine('$debugId: projecting $env...');

    if (!isAttached) {
      logger.warning('$debugId detached attribute is not projecting $env');
      return;
    }

    // Host must listen to only those changes which are addressed to his actor
    if (env.key != id || env.name != name) {
      logger.severe(
          '$debugId received changes which don\'t belong to him. Changes sourceId: ${env.sourceId}');
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

      _watcher?.call(
        ActorQueryPath.root(viewName),
      );

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

    _watcher?.call(
      ActorQueryPath.root(viewName),
    );

    logger.info('$debugId: projected $env');
  }

  Future<void> _projectLast(
    String name,
    Map<String, dynamic> attr,
    ChangeEnvelop2 env,
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
    ChangeEnvelop2 env,
  ) async {
    for (final change in env.changes) {
      if (attr.isEmpty) {
        attr['value'] = _getProjectedValue(attr, change);
        logger.info(
          '$debugId: created $name with value -> ${attr['value']}',
        );
        continue;
      }

      attr['value'] = _getProjectedValue(attr, change);
      logger.info(
        '$debugId: new value -> ${attr['value']}',
      );
    }

    attr['version'] = env.changeId;
    logger.info(
      '$debugId: new ver -> ${attr['version']}',
    );
  }

  dynamic _getProjectedValue(Map<String, dynamic> attr, Change change) {
    return switch (change) {
      RefValueAttributeChanged2() => _onRefValueAttributeChanged(attr, change),
      CounterAttrIncremented2() => _onCounterAttrIncremented(attr, change),
      CounterAttrDecremented2() => _onCounterAttrDecremented(attr, change),
      CounterAttrReset2() => _onCounterAttrReset(attr, change),
      _ => throw FluirError(
          'Unsupported attribute change type - ${change.runtimeType}.'),
    };
  }

  dynamic _onRefValueAttributeChanged(
    Map<String, dynamic> attr,
    RefValueAttributeChanged2 change,
  ) {
    return change.newValue;
  }

  dynamic _onCounterAttrIncremented(
    Map<String, dynamic> attr,
    CounterAttrIncremented2 change,
  ) {
    return (attr['value'] ?? 0) + change.by;
  }

  dynamic _onCounterAttrDecremented(
    Map<String, dynamic> attr,
    CounterAttrDecremented2 change,
  ) {
    return (attr['value'] ?? 0) - change.by;
  }

  dynamic _onCounterAttrReset(
    Map<String, dynamic> attr,
    CounterAttrReset2 change,
  ) {
    return change.newValue;
  }

  /// Key is attribute name
  /// Value is [Map] with attribute's value and version
  final _attrs = <String, dynamic>{};

  /// Key is attribute name
  /// Value is the subscription to attribute's changes
  final _subs = <String, StreamSubscription<ChangeEnvelop2>>{};

  ActorQueryPathFunc? _watcher;
}
