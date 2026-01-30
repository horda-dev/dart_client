// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'system.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$SendCallLabelsToJson(SendCallLabels instance) =>
    <String, dynamic>{
      'senderId': instance.senderId,
      'entityId': instance.entityId,
      'entityName': instance.entityName,
    };

Map<String, dynamic> _$DispatchLabelsToJson(DispatchLabels instance) =>
    <String, dynamic>{'senderId': instance.senderId};

TestAuthEvent _$TestAuthEventFromJson(Map<String, dynamic> json) =>
    TestAuthEvent(json['credential'] as String);

Map<String, dynamic> _$TestAuthEventToJson(TestAuthEvent instance) =>
    <String, dynamic>{'credential': instance.credential};
