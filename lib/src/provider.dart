import 'package:horda_core/horda_core.dart';
import 'package:flutter/widgets.dart';

import 'connection.dart';
import 'query.dart';
import 'system.dart';

enum HordaModelAspect { authState, connectionState }

class HordaSystemProvider extends InheritedModelNotifier<HordaModelAspect> {
  HordaSystemProvider({Key? key, required this.system, required Widget child})
    : super(key: key, child: child) {
    system.conn.addListener(() {
      aspectChanges.add(HordaModelAspect.connectionState);
    });

    system.authState.addListener(() {
      aspectChanges.add(HordaModelAspect.authState);
    });
  }

  final HordaClientSystem system;

  @override
  InheritedElement createElement() {
    return FluirSystemProviderElement(this);
  }

  @override
  bool updateShouldNotifyDependent(
    Set<HordaModelAspect> changes,
    Set<HordaModelAspect> dependencies,
  ) {
    return dependencies.intersection(changes).isNotEmpty;
  }

  static HordaClientSystem of(BuildContext context) {
    final provider = context
        .findAncestorWidgetOfExactType<HordaSystemProvider>();

    if (provider == null) {
      throw FluirError('no FluirSystemProvider found');
    }
    return provider.system;
  }

  static HordaConnectionState connectionStateOf(BuildContext context) {
    return InheritedModelNotifier.inheritFrom<HordaSystemProvider>(
      context,
      aspect: HordaModelAspect.connectionState,
    ).system.conn.value;
  }

  static HordaAuthState authStateOf(BuildContext context) {
    return InheritedModelNotifier.inheritFrom<HordaSystemProvider>(
      context,
      aspect: HordaModelAspect.authState,
    ).system.authState.value;
  }
}

sealed class HordaAuthState {}

class AuthStateValidating implements HordaAuthState {}

class AuthStateIncognito implements HordaAuthState {}

class AuthStateLoggedIn implements HordaAuthState {
  AuthStateLoggedIn({required this.userId});

  final String userId;
}
