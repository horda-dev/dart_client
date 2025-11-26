# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Horda Client SDK for Flutter** - a client library that connects Flutter apps to backends built with the Horda platform. It provides real-time entity queries, WebSocket-based subscriptions, and strongly-typed data access.

Key dependencies:
- Flutter SDK >=3.10.0
- Dart SDK >=3.8.0
- `horda_core` (local path: ../dart_core) - shared core types and protocols
- `json_annotation` + `build_runner` for code generation

## Commands

### Running Tests
```bash
# Run all tests
flutter test

# Run a specific test file
flutter test test/query/query_host_test.dart

# Run a specific test by name pattern
flutter test --name "should track subscriptions"

# Run with verbose output
flutter test --reporter expanded

# Run widget tests specifically
flutter test test/system/
```

### Code Generation
```bash
# Generate .g.dart files for JSON serialization and other annotations
dart run build_runner build

# Watch mode for continuous generation during development
dart run build_runner watch

# Clean generated files
dart run build_runner clean
```

Files requiring generation (have `part '*.g.dart'` directive):
- `lib/src/system.dart`
- `lib/src/devtool.dart`

### Linting and Formatting
```bash
# Analyze code
dart analyze

# Format code (preserves trailing commas per analysis_options.yaml)
dart format .
```

## Versioning and Changelog

### Updating the Changelog

When updating `CHANGELOG.md` for a new release:

1. **Check `.pubignore`** - Review the `.pubignore` file to identify files excluded from publication
2. **Exclude unpublished changes** - Do NOT document changes to files listed in `.pubignore` in the changelog, as these changes won't affect published users
3. **Current exclusions** (as of this writing):
   - `CLAUDE.md` - Internal documentation for Claude Code (not published to pub.dev)
4. **Focus on public API** - Only document changes that affect the published package and its users

Example: Adding or modifying `CLAUDE.md` should not appear in the changelog since it's excluded from publication.

### Version Bumping

Follow semantic versioning (semver):
- **PATCH** (0.0.x): Bug fixes, documentation updates (published files only)
- **MINOR** (0.x.0): New features, deprecated APIs (backward compatible)
- **MAJOR** (x.0.0): Breaking changes to public API

Update both:
- `pubspec.yaml` - `version:` field
- `CHANGELOG.md` - Add new section at the top with version number and changes

## Architecture

### Core Concepts

The SDK implements a **real-time entity query system** with automatic subscription management:

1. **Queries** (`lib/src/query.dart`): Define what data to fetch from backend entities
   - `EntityQuery` - Base class for defining queries (maps to backend EntityViewGroups)
   - View types: `EntityValueView`, `EntityCounterView`, `EntityRefView`, `EntityListView`, `EntityDateTimeView`
   - Supports nested entity graphs (references and lists)

2. **Hosts** (`lib/src/query.dart`): Manage query execution and view subscriptions
   - `ActorQueryHost` - Manages query lifecycle, state, and child view hosts
   - `ActorViewHost` (and subclasses) - Manages individual view subscriptions and change propagation
   - Host hierarchy mirrors the query structure (tree of queries → tree of hosts)

3. **System** (`lib/src/system.dart`): Central coordinator
   - `HordaClientSystem` - Main entry point, manages connection and global state
   - **Reference counting for view subscriptions**: Tracks how many widgets subscribe to each view
     - Calls `subscribeViews()` when ref count goes 0→1
     - Calls `unsubscribeViews()` when ref count goes 1→0
     - Stored in `_viewSubCount` map (key: entityName/entityId/viewName)
   - `TestHordaClientSystem` - Test subclass that exposes `viewSubCount` for verification

4. **Connection** (`lib/src/connection.dart`): WebSocket communication layer
   - `Connection` interface - Abstract protocol for backend communication
   - `WebSocketConnection` - Production implementation
   - **Atomic query + subscribe**: `queryAndSubscribe()` prevents race conditions

### Query-Host Architecture

The query/host system follows a **parallel tree structure**:

```
EntityQuery (defines WHAT to query)
  └─ EntityView (view1, view2, refView, listView)
       └─ Nested EntityQuery (for refs/lists)

ActorQueryHost (manages execution)
  └─ ActorViewHost (manages subscriptions)
       └─ Child ActorQueryHost (for nested queries)
```

Key flow:
1. `EntityQueryProvider` widget creates `ActorQueryHost` on mount
2. Host calls `run()` → `queryAndSubscribe()` → `attach()`
3. `attach()` iterates through query result views and attaches them to corresponding view hosts
4. **Critical**: Mock `QueryResult` must match the query structure exactly (see test fixes)
5. View hosts register subscriptions with system for reference counting
6. On dispose: hosts untrack subscriptions, system calls `unsubscribeViews()` when ref count reaches 0

## Testing Guidelines

### Mock Connection Pattern

When testing subscription behavior, mock connections must return query results that **exactly match** the requested `QueryDef`:

```dart
// WRONG: Returns all views regardless of query
QueryResult _createMockResult(String actorId, QueryDef def) {
  return QueryResultBuilder()
    ..val('view1', 'value', '1:0:0:0')  // Always returns view1
    ..val('view2', 42, '1:0:0:0');       // Always returns view2
}

// CORRECT: Recursively builds result from QueryDef
void _buildViewsFromDef(String actorId, QueryDef def, QueryResultBuilder builder) {
  for (var entry in def.views.entries) {
    if (entry.value is ValueQueryDef) {
      builder.val(entry.key, mockValue, '1:0:0:0');
    } else if (entry.value is RefQueryDef) {
      builder.ref(entry.key, refId, {}, '1:0:0:0', (refBuilder) {
        _buildViewsFromDef(refId, entry.value.query, refBuilder);
      });
    } // ... handle list views similarly
  }
}
```

See `test/system/view_tracking_widget_test.dart` for the full pattern.

### Reference Counting Tests

When verifying subscription behavior:
- Check exact unsubscribe counts: `expect(mockConn.unsubscribeCallLog[0].length, 2)`
- For non-deterministic order: Use `contains(hasLength(N))` matcher
- Verify ref count doesn't trigger unsubscribe while > 0
- Each view key should have exactly 1 `ActorViewSub` in unsubscribe calls

### Test System Setup

Use `TestHordaClientSystem` for widget tests:
```dart
late MockConnection mockConn;
late TestHordaClientSystem system;

setUp(() {
  mockConn = MockConnection();
  system = TestHordaClientSystem.withConnection(connection: mockConn);
});

// Access subscription counts for verification
final counts = system.viewSubCount;
```

## Important Patterns

### Subscription Management
- `subscribeViews()` is deprecated - use atomic `queryAndSubscribe()` instead
- `unsubscribeViews()` is still used on widget disposal
- System tracks view subscriptions with reference counting to avoid duplicate subscriptions

### Error Handling in Queries
Query execution errors are caught and logged in `ActorQueryHost.run()`:
```dart
try {
  final result = await system.queryAndSubscribe(...);
  attach(actorId, result);  // This can throw if views don't match!
} catch (e) {
  _changeState(EntityQueryState.error);
  logger.severe('query ran with error: $e');
  // Error is NOT re-thrown - check query state to detect errors
}
```

### Widget Rebuild Dependencies
Widgets automatically rebuild when queried views change via `context.query<T>()` - this creates a reactive dependency using InheritedWidget infrastructure.
