# Horda Client SDK for Flutter

Horda Client SDK connects your Flutter app to your app's backend running on Horda platform.

## Table of Content
- [Connection management](#connection-management)
- [Authentication](#authentication)
- [Creating Queries to query entity's views](#creating-queries-to-query-entitys-views)
    - [create root query class](#create-root-query-class)
    - [query related entities](#query-related-entities)
- [Running Queries](#running-queries)
    - [add query widget](#add-query-widget)
    - [query state](#query-state)
- [Getting query results and updating app data in real-time](#getting-query-results-and-updating-app-data-in-real-time)
- [Starting backend business processes and getting results](#starting-backend-business-processes-and-getting-results)
    - [add backend pkg dep to pubspec.yaml](#add-backend-pkg-dep-to-pubspecyaml)

## Connection management

### Setup Connection

Initialize the Horda Client System with your project configuration:

```dart
import 'package:horda_client/horda_client.dart';

// 1. Configure connection
final projectId = '[YOUR_PROJECT_ID]';
final apiKey = '[YOUR_API_KEY]';
final url = 'wss://api.horda.ai/$projectId/client';

// 2. Create connection config
final conn = NoAuthConfig(url: url, apiKey: apiKey);
// Or for authenticated users:
// final conn = LoggedInConfig(url: url, apiKey: apiKey);

// 3. Initialize system
final system = HordaClientSystem(conn, NoAuth());
system.start();

// 4. Wrap your app with the provider
runApp(HordaSystemProvider(system: system, child: MyApp()));
```

### Connection States

The SDK automatically manages connection states and reconnects in case of lost connectivity:

```dart
// Access connection state in your widgets
Widget build(BuildContext context) {
  final connectionState = context.hordaConnectionState;
  
  return switch (connectionState) {
    ConnectionStateDisconnected() => Text('Disconnected'),
    ConnectionStateConnecting() => Text('Connecting...'),
    ConnectionStateConnected() => Text('Connected'),
    ConnectionStateReconnecting() => Text('Reconnecting...'),
    ConnectionStateReconnected() => Text('Reconnected'),
  };
}
```

## Authentication

### Setup Authenticated Connection

For applications requiring user authentication, use `LoggedInConfig` with a JWT token provider:

```dart
import 'package:horda_client/horda_client.dart';

class MyAuthProvider implements AuthProvider {
  @override
  Future<String?> getIdToken() async {
    // Retrieve JWT token from your authentication service
    // This could be Firebase Auth, Auth0, or your custom JWT provider
    final token = await getCurrentUserJwtToken();
    return token;
  }
}

// Configure authenticated connection
final projectId = '[YOUR_PROJECT_ID]';
final apiKey = '[YOUR_API_KEY]';
final url = 'wss://api.horda.ai/$projectId/client';

final conn = LoggedInConfig(url: url, apiKey: apiKey);
final system = HordaClientSystem(conn, MyAuthProvider());
system.start();

runApp(HordaSystemProvider(system: system, child: MyApp()));
```

By default, Horda Client opens an unauthenticated connection using `NoAuthConfig`. Use `LoggedInConfig` when your backend requires user authentication and authorization.

### Authentication States

The SDK supports multiple authentication states:

```dart
Widget build(BuildContext context) {
  final authState = context.hordaAuthState;
  
  return switch (authState) {
    AuthStateIncognito() => LoginScreen(),
    AuthStateValidating() => LoadingScreen(),
    AuthStateLoggedIn() => HomeScreen(),
  };
}
```

### Get User ID

```dart
// Get current authenticated user ID (null if not logged in)
final userId = context.hordaAuthUserId;
```

### Logout

```dart
// Logout and switch to incognito mode
context.logout();
```

## Creating Queries to query entity's views

Client queries interact with **Entity View Groups** defined on your Horda backend. When you define an entity on the server (using [Horda Server SDK](../dart_server/README.md#views)), you create view groups that expose read-optimized data representations. Client queries map directly to these backend views, creating a strongly-typed contract between your Flutter app and backend.

The query API provides **full type safety** with all the benefits of Dart's strong typing system:
- Compile-time error checking for view names and types
- IDE auto-completion and refactoring support  
- Runtime type safety preventing data access errors
- Clear documentation through type definitions

### Create root query class

Define query classes to specify which data you need from entities:

```dart
class CounterQuery extends EntityQuery {
  final counterName = EntityValueView<String>('name');
  final counterValue = EntityCounterView('value');
  final freezeStatus = EntityValueView<String>('freezeStatus');

  @override
  void initViews(EntityQueryGroup views) {
    views
      ..add(counterName)
      ..add(counterValue)
      ..add(freezeStatus);
  }
}
```

### Query related entities (entity graphs)

Entities can reference other entities, forming an **entity relationship graph**. For example, a User might reference a Profile entity, which in turn references Address entities. With Horda Client queries, you can fetch arbitrary complex subgraphs of related entities in a single query.

This eliminates the need for multiple round-trips and allows you to declaratively specify exactly what data your UI needs, whether it's a single entity or a complex network of related data spanning multiple entity types.

#### Reference Views (single entity)
```dart
class UserQuery extends EntityQuery {
  final profile = EntityRefView<ProfileQuery>(
    'profile',
    query: ProfileQuery(),
  );

  @override
  void initViews(EntityQueryGroup views) {
    views.add(profile);
  }
}
```

#### List Views (multiple entities)
```dart
class CounterListQuery extends EntityQuery {
  final counters = EntityListView('counters', query: CounterQuery());

  @override
  void initViews(EntityQueryGroup views) {
    views.add(counters);
  }
}
```

#### Available View Types
- `EntityValueView<T>('viewName')` - Single values (String, int, bool, etc.)
- `EntityCounterView('viewName')` - Counter values with increment/decrement
- `EntityDateTimeView('viewName', isUtc: true)` - DateTime values
- `EntityRefView<QueryType>('viewName', query: QueryType())` - Single entity reference
- `EntityListView<QueryType>('viewName', query: QueryType())` - List of entities

More view types coming soon.

## Running Queries

### Add query widget

Use `entityQuery` to run queries and handle loading/error states:

```dart
Widget build(BuildContext context) {
  return context.entityQuery(
    entityId: 'counter-123',
    query: CounterQuery(),
    loading: CircularProgressIndicator(),
    error: Text('Error loading data'),
    child: CounterWidget(),
  );
}
```

### Query state

Monitor query execution state:

```dart
Widget build(BuildContext context) {
  final query = context.query<CounterQuery>();
  
  return switch (query.state()) {
    EntityQueryState.created => CircularProgressIndicator(),
    EntityQueryState.loaded => CounterContent(),
    EntityQueryState.error => ErrorWidget(),
    EntityQueryState.stopped => Container(),
  };
}
```

## Getting query results and updating app data in real-time

### Access Query Data

When you access query data inside a widget using `context.query<T>()`, you automatically create a **reactive dependency** between that widget and the queried view values. The widget will be rebuilt every time the view's value changes on the backend - **no additional setup required**.

This provides real-time UI updates with zero boilerplate code. As soon as your backend entities change (through business processes), your Flutter UI automatically reflects those changes.

```dart
class CounterWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Find the query from the BuildContext by the query type
    final query = context.query<CounterQuery>();
    
    // Get values from views and get this widget updated on values changes
    final name = query.value((q) => q.counterName);
    final value = query.counter((q) => q.counterValue);
    final status = query.value((q) => q.freezeStatus);
    
    return Column(
      children: [
        Text('Counter: $name'),
        Text('Value: $value'),
        Text('Status: $status'),
      ],
    );
  }
}
```

### Working with References

```dart
// Access referenced entity data (when reference is guaranteed to exist)
final profileName = userQuery
                      .ref((q) => q.profile)
                      .value((q) => q.name);

// Access optional references that might be null
final nullableProfileName = userQuery
                              .maybeRef((q) => q.profile)
                              .value((q) => q.name);
```

### Working with Lists

```dart
// Get list items
final counters = query.listItems((q) => q.counters);

// Access individual list items
final firstCounter = query.listItem((q) => q.counters, 0);
final firstName = firstCounter.value((q) => q.counterName);

```

### Value Change Handlers

Value change handlers are designed for cases where you need to execute **custom code** when specific values change, such as triggering Flutter animations, showing notifications, or logging events. For normal UI updates, the automatic real-time updates work out of the box without any additional setup.

Use change handlers when you need programmatic reactions to data changes rather than just UI rebuilds:

Listen to specific view changes for reactive updates:

```dart
class CounterWidget extends StatefulWidget {
  @override
  State<CounterWidget> createState() => _CounterWidgetState();
}

class _CounterWidgetState extends State<CounterWidget> 
    with ChangeHandlerState<CounterWidget> {
  
  @override
  Widget build(BuildContext context) {
    final query = context.query<CounterQuery>();
    
    // Add change handlers
    query
      .addValueHandler((q) => q.counterName)
      .onValueChanged((change) {
        print('Counter name changed to: ${change.newValue}');
        // run an animation
      });
      
    query
      .addCounterHandler((q) => q.counterValue)
      ..onIncremented((change) => print('Incremented by ${change.by}'))
      ..onDecremented((change) => print('Decremented by ${change.by}'))
      ..onReset((change) => print('Reset to ${change.newValue}'));
    
    // Widget content...
  }
}
```

## Starting backend business processes and getting results

### Dispatch Events

Send events to trigger backend business processes:

```dart
class CounterViewModel {
  final HordaClientSystem system;
  final String counterId;
  
  CounterViewModel(BuildContext context, this.counterId) 
    : system = HordaSystemProvider.of(context);

  Future<void> increment() async {
    final result = await system.dispatchEvent(
      IncrementCounterRequested(counterId: counterId, amount: 1),
    );
    
    // Handle result
    if (result.isSuccess) {
      print('Counter incremented successfully');
    } else {
      print('Error: ${result.error}');
    }
  }
  
  Future<void> createCounter(String name) async {
    await system.dispatchEvent(
      CreateCounterRequested(name: name),
    );
  }
}
```

### Send Commands

Send commands directly to specific entities:

```dart
// Send command without waiting for response
await system.sendRemote('Counter', counterId, IncrementCommand(by: 1));

// Call command and wait for response
final response = await system.callRemote(
  'Counter', 
  counterId, 
  GetCounterStatusCommand(),
);
```

### Add backend pkg dep to pubspec.yaml

Add your backend package to access event and command definitions:

```yaml
dependencies:
  flutter:
    sdk: flutter
  horda_client: ^1.0.0
  your_backend_package:
    path: ../backend  # or pub.horda.ai reference

dev_dependencies:
  flutter_test:
    sdk: flutter
```

Then import and use your backend events:

```dart
import 'package:your_backend_package/events.dart';

// Now you can use your custom events
await system.dispatchEvent(YourCustomEvent(data: 'example'));
```
