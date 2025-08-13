import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';

abstract class LocalMessage extends Notification implements Message {
  @override
  String format() => '';

  @override
  String toString() => '$runtimeType(${format()})';
}

abstract class LocalCommand extends LocalMessage {}

abstract class LocalEvent extends LocalMessage {}
