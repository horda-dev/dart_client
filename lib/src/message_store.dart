import 'dart:async';

import 'package:horda_core/horda_core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'connection.dart';
import 'system.dart';

class ClientMessageStore {
  ClientMessageStore(this.system, this.conn)
    : logger = Logger('Fluir.MessageStore');

  final HordaClientSystem system;

  final Connection conn;

  final Logger logger;

  CommandId send(
    EntityId from,
    EntityId to,
    RemoteCommand cmd, [
    bool local = false,
  ]) {
    throw UnsupportedError('for server side usage only');
  }

  Future<RemoteEvent> call(
    EntityId from,
    EntityId to,
    RemoteCommand cmd, [
    bool local = false,
  ]) async {
    throw UnsupportedError('for server side usage only');
  }

  void publishChange(ChangeEnvelop change) {
    logger.fine('publishing change $change...');

    _saveChange(change);
    _changes.add(change);

    logger.info('published change $change from ${change.sourceId}');
  }

  /// Returns an [Iterable] with one [ChangeEnvelop] which contains all past changes.
  Iterable<ChangeEnvelop> changeHistory({
    required String entityName,
    required EntityId id,
    required String name,
    required String startAt,
  }) {
    final logId = '$entityName/$id/$name';

    final fullName = '$logId starting at $startAt';

    logger.fine('changes: getting for $fullName...');

    final log = _changeStore[logId];

    if (log == null) {
      logger.fine('changes: no log found for $fullName');
      return [];
    }

    // was e.version == startAt + 1
    final startAtChId = ChangeId.fromString(startAt);
    final idx = log.indexWhere(
      (e) => ChangeId.fromString(e.changeId) > startAtChId,
    );
    if (idx == -1) {
      logger.fine('changes: no changes found for $fullName');
      return [];
    }

    final range = log.getRange(idx, log.length);

    logger.info('changes: got ${range.length} changes for $fullName');

    return [...range];
  }

  String? latestStoredChangeId({
    required String entityName,
    required EntityId id,
    required String name,
  }) {
    final logId = '$entityName/$id/$name';

    logger.fine('Getting latest version of $logId');

    final log = _changeStore[logId];

    if (log == null || log.isEmpty) {
      logger.fine('Latest version: no log found for $logId');
      return null;
    }

    return log.last.changeId;
  }

  // startAt is a view state version which
  // we want to start getting events at
  Stream<ChangeEnvelop> changes({
    required String entityName,
    required EntityId id,
    required String name,
    String startAt = '',
  }) {
    Stream<ChangeEnvelop> past;
    // TODO: do we need this?
    if (startAt != '-1') {
      past = Stream.fromIterable(
        // Make stream from a copy of history to avoid 'Concurrent Modification' exception
        [
          ...changeHistory(
            entityName: entityName,
            id: id,
            name: name,
            startAt: startAt,
          ),
        ],
      );
    } else {
      past = Stream.empty();
    }

    var future = _changes.stream.where(
      (e) => e.entityName == entityName && e.key == id && e.name == name,
    );

    return Rx.concatEager([past, future]);
  }

  Stream<ChangeEnvelop> futureChanges({
    required String entityName,
    required EntityId id,
    required String name,
  }) {
    return _changes.stream.where(
      (e) => e.entityName == entityName && e.key == id && e.name == name,
    );
  }

  /// Removes stored changes up to a certain version passed.
  /// Changes are removed if their version is LESS or EQUAL to [upToVersion].
  void removeChanges({
    required String entityName,
    required String id,
    required String name,
    required String upToVersion,
  }) {
    final key = '$entityName/$id/$name';

    if (!_changeStore.containsKey(key)) {
      logger.fine(
        'View $key isn\'t present in the store yet, no old changes need to be removed.',
      );
      return;
    }

    final changes = _changeStore[key]!;
    final upToChId = ChangeId.fromString(upToVersion);
    changes.removeWhere((e) => ChangeId.fromString(e.changeId) <= upToChId);

    logger.fine(
      'Removed changes of view $key up to and including version $upToVersion',
    );
  }

  ChangeEnvelop firstChange(EntityId actorId, String viewName) {
    throw UnimplementedError('client message store does not support this');
  }

  /// Clears local storage of [Change]s and [RemoteEvent]s.
  void clear() {
    _changeStore.clear();
  }

  void _saveChange(ChangeEnvelop e) {
    if (e.changes.isEmpty) {
      return;
    }

    final logId = '${e.entityName}/${e.key}/${e.name}';
    final log = _changeStore[logId] ?? [];

    logger.fine('saving changes $e to $logId...');

    if (log.isEmpty) {
      log.add(e);
      _changeStore[logId] = log;
      logger.fine('saved first changes $e to $logId');
      return;
    }

    logger.fine('saving change $e to $logId...');

    if (ChangeId.fromString(log.last.changeId) >=
        ChangeId.fromString(e.changeId)) {
      logger.info(
        'ignore past change with changeId ${e.changeId} for $logId with changeId ${log.last.changeId}',
      );
      return;
    }

    log.add(e);

    logger.fine('saved change $e to $logId');

    _changeStore.putIfAbsent(logId, () => log);
  }

  // maps actor id to change lod
  final _changeStore = <String, List<ChangeEnvelop>>{};

  final _changes = StreamController<ChangeEnvelop>.broadcast();
}
