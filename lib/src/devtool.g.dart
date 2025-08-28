// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'devtool.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DevtoolFluirHostCreated _$DevtoolFluirHostCreatedFromJson(
  Map<String, dynamic> json,
) => DevtoolFluirHostCreated(path: json['path'] as String);

Map<String, dynamic> _$DevtoolFluirHostCreatedToJson(
  DevtoolFluirHostCreated instance,
) => <String, dynamic>{'path': instance.path, 'type': instance.type};

DevtoolFluirHostStopped _$DevtoolFluirHostStoppedFromJson(
  Map<String, dynamic> json,
) => DevtoolFluirHostStopped(path: json['path'] as String);

Map<String, dynamic> _$DevtoolFluirHostStoppedToJson(
  DevtoolFluirHostStopped instance,
) => <String, dynamic>{'path': instance.path, 'type': instance.type};

DevtoolFluirHostProjected _$DevtoolFluirHostProjectedFromJson(
  Map<String, dynamic> json,
) => DevtoolFluirHostProjected(
  path: json['path'] as String,
  envelope: json['envelope'] as String,
  value: json['value'] as String,
  version: json['version'] as int,
);

Map<String, dynamic> _$DevtoolFluirHostProjectedToJson(
  DevtoolFluirHostProjected instance,
) => <String, dynamic>{
  'path': instance.path,
  'type': instance.type,
  'envelope': instance.envelope,
  'value': instance.value,
  'version': instance.version,
};
