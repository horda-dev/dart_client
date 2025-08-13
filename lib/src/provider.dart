import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';

import 'connection.dart';
import 'query.dart';
import 'system.dart';

enum FluirModelAspect {
  authState,
  connectionState,
}

class FluirSystemProvider extends InheritedModelNotifier<FluirModelAspect> {
  FluirSystemProvider({
    Key? key,
    required this.system,
    required Widget child,
  }) : super(key: key, child: child) {
    system.conn.addListener(() {
      aspectChanges.add(FluirModelAspect.connectionState);
    });

    system.authState.addListener(() {
      aspectChanges.add(FluirModelAspect.authState);
    });
  }

  final FluirClientSystem system;

  @override
  InheritedElement createElement() {
    return FluirSystemProviderElement(this);
  }

  @override
  bool updateShouldNotifyDependent(
    Set<FluirModelAspect> changes,
    Set<FluirModelAspect> dependencies,
  ) {
    return dependencies.intersection(changes).isNotEmpty;
  }

  static FluirClientSystem of(BuildContext context) {
    final provider =
        context.findAncestorWidgetOfExactType<FluirSystemProvider>();

    if (provider == null) {
      throw FluirError('no FluirSystemProvider found');
    }
    return provider.system;
  }

  static FluirConnectionState connectionStateOf(BuildContext context) {
    return InheritedModelNotifier.inheritFrom<FluirSystemProvider>(
      context,
      aspect: FluirModelAspect.connectionState,
    ).system.conn.value;
  }

  static FluirAuthState authStateOf(BuildContext context) {
    return InheritedModelNotifier.inheritFrom<FluirSystemProvider>(
      context,
      aspect: FluirModelAspect.authState,
    ).system.authState.value;
  }
}

sealed class FluirAuthState {}

class AuthStateValidating implements FluirAuthState {}

class AuthStateIncognito implements FluirAuthState {}

class AuthStateLoggedIn implements FluirAuthState {
  AuthStateLoggedIn({required this.userId});

  final String userId;
}
