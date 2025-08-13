import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';

part 'devtool.g.dart';

/// An ExtensionKind prefix specifically for the fluir_client devtool.
const kDevtoolExtensionKindPrefix = 'fluir_client:';

/// An event which is sent to Devtools form the inspected application.
sealed class DevtoolExtensionEvent {
  DevtoolExtensionEvent();

  factory DevtoolExtensionEvent.parse(String string) {
    final eventKind = string.replaceFirst(kDevtoolExtensionKindPrefix, '');
    return switch (eventKind) {
      'DevtoolExtensionLoaded' => DevtoolExtensionLoaded(),
      'DevtoolExtensionFluirEventAdded' => DevtoolExtensionFluirEventAdded(),
      _ => throw UnsupportedError('Unknown DevtoolExtensionEvent type'),
    };
  }

  @override
  String toString() {
    return '$kDevtoolExtensionKindPrefix$runtimeType';
  }
}

/// The Load/Reload event which completely reloads the devtool.
class DevtoolExtensionLoaded extends DevtoolExtensionEvent {}

/// A devtool event which logs and processes a [DevtoolFluirEvent].
class DevtoolExtensionFluirEventAdded extends DevtoolExtensionEvent {}

// Implemented events:
// host_created,
// host_stopped,
// host_projected_event,

// Events which are currently not implemented, but can be used in the future:
// host_attached,
// host_detached,
// host_subscribed,
// host_unsubscribed,

/// Any Fluir related event which should be logged and processed by the devtool. <br/>
/// E.g.: host was created, host projected an event, host was stopped, etc.
sealed class DevtoolFluirEvent {
  DevtoolFluirEvent({required this.path});

  /// The destination where this event happened. Path is used by the devtool to build and navigate the host tree.
  final String path;

  @JsonKey(includeToJson: true)
  String get type => this.runtimeType.toString();

  factory DevtoolFluirEvent.fromJson(Map<String, dynamic> json) {
    return switch (json['type'] as String) {
      'DevtoolFluirHostCreated' => DevtoolFluirHostCreated.fromJson(json),
      'DevtoolFluirHostStopped' => DevtoolFluirHostStopped.fromJson(json),
      'DevtoolFluirHostProjected' => DevtoolFluirHostProjected.fromJson(json),
      _ => throw (UnsupportedError('Unknown DevtoolFluirEvent type')),
    };
  }

  Map<String, dynamic> toJson();
}

@JsonSerializable()
class DevtoolFluirHostCreated extends DevtoolFluirEvent {
  DevtoolFluirHostCreated({required super.path});

  factory DevtoolFluirHostCreated.fromJson(Map<String, dynamic> json) {
    return _$DevtoolFluirHostCreatedFromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return _$DevtoolFluirHostCreatedToJson(this);
  }
}

@JsonSerializable()
class DevtoolFluirHostStopped extends DevtoolFluirEvent {
  DevtoolFluirHostStopped({required super.path});

  factory DevtoolFluirHostStopped.fromJson(Map<String, dynamic> json) {
    return _$DevtoolFluirHostStoppedFromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return _$DevtoolFluirHostStoppedToJson(this);
  }
}

@JsonSerializable()
class DevtoolFluirHostProjected extends DevtoolFluirEvent {
  DevtoolFluirHostProjected({
    required super.path,
    required this.envelope,
    required this.value,
    required this.version,
  });

  final String envelope;
  final String value;
  final int version;

  factory DevtoolFluirHostProjected.fromJson(Map<String, dynamic> json) {
    return _$DevtoolFluirHostProjectedFromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return _$DevtoolFluirHostProjectedToJson(this);
  }
}

/// This class is used to store and provide [DevtoolFluirEvent]s for the devtool. <br/>
/// It communicates with the devtool by posting [DevtoolExtensionEvent]s where the payload is a [DevtoolFluirEvent].
class DevtoolEventLog {
  DevtoolEventLog._();

  static final _instance = kDebugMode
      ? DevtoolEventLog._()
      : throw UnsupportedError('Cannot use DevtoolEventLog in release mode');

  /// Intended to be used outside the 'devtool.dart'.
  /// Stores and sends a [DevtoolFluirEvent] to the devtool if running in debug mode, if not - does nothing.
  /// Current mode is checked via [kDebugMode].
  static void sendToDevtool(DevtoolFluirEvent event) {
    if (kDebugMode) {
      DevtoolEventLog._instance.addEvent(event);
    }
  }

  final _log = <DevtoolFluirEvent>[];

  /// Adds a [DevtoolFluirEvent] to the log and sends it to the devtool.
  /// The devtool should store and process this event.
  void addEvent(DevtoolFluirEvent fluirEvent) {
    // Add to log, so devtool can init from it or reload with it later.
    _log.add(fluirEvent);
    // Post an event to our devtools extension
    dev.postEvent('${DevtoolExtensionFluirEventAdded()}', fluirEvent.toJson());
  }

  List<Map<String, dynamic>> toJson() {
    return [..._log.map((e) => e.toJson())];
  }

  /// This method is intended to be called via evalOnDart by devtool on initState and via designated "Reload" button
  /// <br/><br/>
  /// Posts a [DevtoolExtensionLoaded] event with all currently stored [DevtoolFluirEvent]s to the devtool.
  /// The devtool should load/reload after receiving this event.
  void loadDevtool() {
    dev.postEvent(
      '${DevtoolExtensionLoaded()}',
      {'log': toJson()},
    );
  }
}
