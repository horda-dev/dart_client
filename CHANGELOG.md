## 0.23.0

- **FEAT**: support WebSocket connection on web platform
- **FEAT**: use horda_core 0.16.0

## 0.22.0

- **FEAT**: use horda_core 0.15.0

## 0.21.0

- **BREAKING CHANGE**: entity queries now require an entity name
- **FEAT**: entity name is now part of view key
- **FEAT**: use horda_core 0.14.0

## 0.20.0

- **BREAKING CHANGE**: update Auth API, connection configs were removed

## 0.19.1

 - **DOCS**: add README.md
 - **DOCS**: add doc comments to the main public APIs

## 0.19.0

 - **BREAKING CHANGE**: rename public API: Fluir->Horda, Actor->Entity, Flow->Process.
 - Update horda_core dependency to 0.13.2.

## 0.18.0

 - **BREAKING CHANGE**: rename public API.

## 0.17.18

 - **FEAT**: service type.

## 0.17.17

 - **FEAT**: scale actor processor, fix ValueViewChangedHandler type error.

## 0.17.16+2

 - **FIX**: fix ValueViewChanged fromJson.

## 0.17.16+1

 - Update a dependency to the latest release.

## 0.17.16

 - **FEAT**: remove flow subs.

## 0.17.15

 - **FEAT**: query change handler.

## 0.17.14

 - **FEAT**: sync actor start.

## 0.17.13+6

 - **FIX**: int overflow when calculating reconnection delay.

## 0.17.13+5

 - **FIX**: revert client query delay change.

## 0.17.13+4

 - **FIX**: increase call and dispatch timeout, and client query delay.

## 0.17.13+3

 - **FIX**: clear cache on logout and changeConnection.

## 0.17.13+2

 - **FIX**: report connection errors.

## 0.17.13+1

 - **FIX**: widgets depending on list view items don't rebuild.

## 0.17.13

 - **FEAT**: add breadcrumb parameters.

## 0.17.12+3

 - **FIX**: connection state on closing and reconnecting.

## 0.17.12+2

 - **FIX**: watcher callback is called on unmounted element.

## 0.17.12+1

 - Update a dependency to the latest release.

## 0.17.12

 - **FEAT**: report client messages to analytics service.

## 0.17.11+1

 - **FIX**: delay MeQuery.

## 0.17.11

 - **FEAT**: update fluir client to fluir 2.

## 0.17.10+2

 - Update a dependency to the latest release.

## 0.17.10+1

 - Update a dependency to the latest release.

## 0.17.10

 - **FEAT**: fluir client v2.

## 0.17.9+5

 - Update a dependency to the latest release.

## 0.17.9+4

 - Update a dependency to the latest release.

## 0.17.9+3

 - Update a dependency to the latest release.

## 0.17.9+2

 - Update a dependency to the latest release.

## 0.17.9+1

 - Update a dependency to the latest release.

## 0.17.9

 - **FEAT**: auth provider.

## 0.17.8+2

 - **FIX**: system.reopen() breaks rebuilds on connection state change.

## 0.17.8+1

 - Update a dependency to the latest release.

## 0.17.8

 - **FEAT**: added BuildContext.logout() method.

## 0.17.7

 - **FIX**: await onNewUser handler in memhost, fix client flow late initialization error.
 - **FEAT**: implement unsubscribe actor functionality.

## 0.17.6

 - **FEAT**: implement unsubscribe actor functionality.

## 0.17.5

 - **FEAT**: attribute version in query result, init of auth state based on auth config, renamed AuthStateUnknown to AuthStateValidating.

## 0.17.4+4

 - **FIX**: view host can detach while async projector is executing.

## 0.17.4+3

 - **FIX**: init _attrs when starting attrHost without query result.

## 0.17.4+2

 - **FIX**: honor query subscribe value.

## 0.17.4+1

 - **FIX**: command type mismatch when handling local commands.

## 0.17.4

 - **FEAT**: rerun root queries on reconnect.

## 0.17.3+2

 - **FIX**: ListView doesn't report ready in time if last initial change doesn't add an item.

## 0.17.3+1

 - **FIX**: no reconnect on connection lost.

## 0.17.3

 - **FEAT**: view cache.

## 0.17.2+1

 - **FIX**: subqueries of ref/list view report their parent view state as ready too early.

# 0.17.2

- fixed attribute change not being projected
- added AttributesHost

# 0.17.1

- fixed null return from valueAttr() of a ListView

# 0.17.0

- added API to ActorListView to query and get attributes of value type

# 0.16.0

- added ListView.addItemIfAbsent()
- updated fluir_core to 0.11.0

# 0.15.0

- delayed changing query state to 'loaded' until views project at least one remote change
- renamed system.history() to changeHistory, added futureChanges() method 
- updated fluir_core to 0.10.0

# 0.14.0

- added API to ActorRefView and ActorListView to query and get attribute values
- updated fluir_core to 0.9.0

# 0.13.0

- added dispatchEvent() which let the client send an Event and await a FlowResult
- updated fluir_core to 0.8.0

# 0.12.0

- refactored messages into remote and local messages
- updated fluir_core to 0.7.0

# 0.11.1

- fix potential 'Concurrent modification' error

# 0.11.0

- refactored view Events into Changes
- delayed widget rebuild when projecting multiple changes from ChangeEnvelop

# 0.10.1

- fixed duplicate view subbing and unsubbing

# 0.10.0

- added reconnect method to FluirFlowContext

# 0.9.0

- added authState getter to FluirFlowContext

# 0.8.0

- make ConnectionConfig a sealed class with several options: IncognitoConfig, LoggedInConfig, NewUserConfig
- renamed reconnect() to reopen() in FluirClientSystem

# 0.7.0

- renamed ClientFluirSystem to FluirClientSystem
- removed emit() BuildContext extensions
- unextended FluirClientSystem from FluirSystem

# 0.6.0

- upgraded fluir_core to 0.4.0
- Added change of authStateOf depending on userId

## 0.5.0

- upgraded fluir_core to 0.3.0
- removed send() and sendTo() extensions from BuildContext

## 0.4.0

- new actor and flow classes that communicate using Flutter notifications

## 0.3.0

- added LocalMessage class
- added ProxyActor class

## 0.2.0

- added subscribeActor api to client flow context
- added actorQuery() BuildContext helper to run query with placeholder widgets
- renamed subscribe() to subscribeViews()

## 0.1.2

- added license
- added package publish ci job

## 0.1.1

- fix missing BuildContext api
- export fluir core types

## 0.1.0

- initial release
