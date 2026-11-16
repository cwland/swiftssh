# Milestone 1: Core Models, Encrypted Sync and Sync Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared data models, client-side encryption, the sync engine and the self-hosted Vapor sync server (with Docker packaging), all testable on Linux.

**Architecture:** `Packages/CoreSSH` is a Swift package with two libraries this milestone: `CoreModels` (plain Codable record structs plus host-group logic) and `SyncCore` (encryption, wire types, last-writer-wins merge, sync engine, HTTP transport). `Server/` is a Vapor 4 app on SQLite that depends on `SyncCore` for wire types and the merge rule, and only ever stores encrypted records.

**Tech Stack:** Swift 6.0, swift-crypto 3.x (`Crypto`, `_CryptoExtras`), Vapor 4, Fluent + FluentSQLiteDriver, XCTest / XCTVapor, Docker.

**Spec:** `docs/superpowers/specs/2026-11-13-termius-reimagined-design.md` (§5 Architecture, §6 Data model, §7 Sync, §11 Testing and delivery).

## Global Constraints

- Swift tools version 6.0. `CoreSSH` platforms: `.macOS(.v14), .iOS(.v17)`; must also build on Linux.
- `CoreModels` and `SyncCore` must not import SwiftUI, SwiftData, Security or LocalAuthentication.
- PBKDF2-HMAC-SHA256, production iterations **600,000** (`VaultCrypto.defaultIterations`); salt 16 random bytes. Tests may pass a lower count.
- Records and the vault key are sealed with AES-256-GCM. Record AAD = `"\(id.uuidString)|\(type.rawValue)|\(updatedAtMs)|\(deleted ? 1 : 0)|\(deviceID)"` as UTF-8, where `updatedAtMs` is `Int64` whole milliseconds since 1970 (floored).
- API auth: `Authorization: Bearer <key>`; keys from env `SYNC_API_KEYS` (comma-separated, whitespace trimmed, empties ignored). `GET /health` needs no auth.
- Server listens on 8080; SQLite file from env `DATABASE_PATH` (default `/data/sync.sqlite`).
- Merge rule: newer `updatedAt` wins per whole record; on an exact tie the larger `deviceID` string wins.
- Server logs never contain request bodies.
- Dev sandbox: run `source /usr/local/bin/swiftenv` before any `swift` command (it puts the Swift 6.0.3 toolchain on `PATH`).
- Commits end with the session's attribution trailer lines.

## Review Focus

1. **Clock skew between Macs:** an edit made on a Mac whose clock runs behind must still beat the version that Mac last saw. → `Timestamps.nextUpdate` test in Task 2.
2. **Wrong passphrase on a joining Mac:** nothing is uploaded or overwritten; a clear `SyncError.wrongPassphrase`. → test in Task 8.
3. **Server wiped or rebuilt while Macs still have data:** a client that sees a different `vaultID` (or no vault) re-uploads everything instead of silently stalling at an old `seq`. → test in Task 8.
4. **Oversized or malformed requests:** a 2 MB ciphertext, `limit=100000` or bad JSON get 4xx responses, never a crash or an unbounded query. → tests in Task 7.
5. **Sync interrupted mid-push:** records stay dirty and are re-sent next time; re-sending the same record is harmless. → test in Task 8.

---

## File Structure

```
Packages/CoreSSH/
  Package.swift
  Sources/CoreModels/
    SyncableModel.swift        protocol + SyncRecordType
    Models.swift               Host, HostGroup, Identity, SSHKey, Snippet, KnownHost,
                               ConnectionLog, ShellHistoryEntry, AISettings, OSBadge
    HostQueries.swift          group inheritance, hosts-in-group, tag filter, search
    Timestamps.swift           nextUpdate
  Sources/SyncCore/
    VaultCrypto.swift          key derivation, wrap/unwrap, seal/open
    WireTypes.swift            EncryptedRecord, VaultMetadata, RecordsPage, request bodies
    MergeRule.swift            LWW
    SyncEngine.swift           SyncTransport, SyncLocalStore, PlainRecord, SyncEngine
    HTTPSyncTransport.swift    URLSession transport
  Tests/CoreModelsTests/…, Tests/SyncCoreTests/…
Server/
  Package.swift
  Sources/SyncServer/          configure.swift, routes.swift, APIKeyMiddleware.swift,
                               Models/RecordRow.swift, Models/VaultRow.swift, Migrations.swift,
                               Controllers/VaultController.swift, Controllers/RecordsController.swift
  Sources/Run/main.swift
  Tests/SyncServerTests/…
  Dockerfile, docker-compose.yml, README.md
```

---

### Task 1: CoreSSH package and record models

**Files:**
- Create: `Packages/CoreSSH/Package.swift`, `Sources/CoreModels/SyncableModel.swift`, `Sources/CoreModels/Models.swift`
- Test: `Packages/CoreSSH/Tests/CoreModelsTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum SyncRecordType: String, Codable, Sendable, CaseIterable { case host, hostGroup, identity, sshKey, snippet, knownHost, connectionLog, shellHistory, aiSettings }`
  - `protocol SyncableModel: Codable, Equatable, Sendable, Identifiable where ID == UUID { static var recordType: SyncRecordType { get }; var id: UUID { get }; var updatedAt: Date { get set }; var deleted: Bool { get set } }`
  - Structs (all `SyncableModel`, memberwise inits with defaults matching spec §6):
    - `HostGroup { id, name, parentID: UUID?, defaultIdentityID: UUID?, defaultPort: Int?, defaultThemeID: String?, updatedAt, deleted }`
    - `Host { id, label, address, port: Int? (nil = inherit, effective default 22), groupID: UUID?, tags: [String], username: String?, identityID: UUID?, password: String?, sshKeyID: UUID?, osBadge: OSBadge?, osBadgeIsManual: Bool, themeID: String?, startupSnippetID: UUID?, lastConnectedAt: Date?, updatedAt, deleted }`
    - `Identity { id, label, username, password: String?, sshKeyID: UUID?, updatedAt, deleted }`
    - `SSHKey { id, label, keyType: KeyType (.ed25519, .rsa), publicKey: String, privateKey: String, passphrase: String?, updatedAt, deleted }`
    - `Snippet { id, name, script, package: String?, updatedAt, deleted }`
    - `KnownHost { id, hostPort: String, keyType: String, fingerprintSHA256: String, firstSeen: Date, updatedAt, deleted }`
    - `ConnectionLog { id, hostID: UUID?, hostLabel, username, deviceName, startedAt: Date, endedAt: Date?, saved: Bool, updatedAt, deleted }`
    - `ShellHistoryEntry { id, command, hostID: UUID?, executedAt: Date, updatedAt, deleted }`
    - `AISettings { id, provider: AIProvider (.openAICompatible, .anthropic), baseURL: String, model: String, apiKey: String?, updatedAt, deleted }`
    - `enum OSBadge: String, Codable, Sendable, CaseIterable { ubuntu, debian, raspberryPiOS, fedora, rhel, alpine, arch, macOS, freeBSD, linux, synology, homeAssistant }`

- [ ] **Step 1: Write the failing tests**

```swift
func testEveryModelRoundTripsThroughJSON()   // encode/decode each struct with non-default values; XCTAssertEqual(decoded, original)
func testRecordTypesAreUniquePerModel()      // Set of [Host.recordType, HostGroup.recordType, …].count == SyncRecordType.allCases.count
func testHostDefaults() { let h = Host(label: "Docker", address: "192.168.99.10"); XCTAssertNil(h.port); XCTAssertEqual(h.tags, []); XCTAssertFalse(h.deleted) }
```

Use an `ISO8601`-free `JSONEncoder` with `.dateEncodingStrategy = .millisecondsSince1970`; expose it as `CoreJSON.encoder` / `CoreJSON.decoder` in `SyncableModel.swift` so every module encodes the same way.

- [ ] **Step 2: Run to verify failure** — `cd Packages/CoreSSH && swift test --filter CoreModelsTests` → fails to compile (types missing).
- [ ] **Step 3: Implement** `Package.swift` (products `CoreModels`, `SyncCore`; dependency `swift-crypto` `from: "3.0.0"`; `SyncCore` depends on `CoreModels`, `Crypto`, `_CryptoExtras`), the protocol, `CoreJSON`, and the structs.
- [ ] **Step 4: Run to verify pass** — same command → all pass.
- [ ] **Step 5: Commit** — `git add Packages/CoreSSH && git commit -m "feat(core): add sync record models"`

---

### Task 2: Host queries, inheritance and timestamps

**Files:**
- Create: `Sources/CoreModels/HostQueries.swift`, `Sources/CoreModels/Timestamps.swift`
- Test: `Tests/CoreModelsTests/HostQueriesTests.swift`, `Tests/CoreModelsTests/TimestampsTests.swift`

**Interfaces:**
- Consumes: Task 1 structs.
- Produces:
  - `struct HostDirectory { init(hosts: [Host], groups: [HostGroup]) }` (ignores `deleted` records) with:
    - `func effectivePort(for: Host) -> Int` (host → group chain → 22)
    - `func effectiveIdentityID(for: Host) -> UUID?` (host → group chain)
    - `func effectiveThemeID(for: Host) -> String?`
    - `func hosts(inGroup: UUID?) -> [Host]` (nil = all; otherwise the group and all descendants)
    - `func filter(tags: Set<String>, search: String) -> [Host]` (all tags required; search is case-insensitive over label, address, username and tags; empty search matches all)
  - `enum Timestamps { static func nextUpdate(previous: Date?, now: Date = Date()) -> Date }` returns `max(now, previous + 0.001s)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testPortFallsBackThroughGroupChainThenTo22()   // grandparent.defaultPort = 2222, host in child → 2222; no defaults anywhere → 22; host.port = 2200 → 2200
func testIdentityAndThemeInheritOneSettingAtATime() // group sets identity only, host sets theme only → each resolved independently
func testGroupCycleDoesNotHang()                    // A.parent = B, B.parent = A → effectivePort returns 22
func testHostsInGroupIncludesSubgroups()            // host in child group appears in hosts(inGroup: parent.id)
func testTagFilterRequiresAllTags()                 // tags ["prod","docker"] → only hosts having both
func testSearchMatchesLabelAddressUsernameAndTag()  // "pihole", "192.168.99", "root", "docker" each find the right hosts, case-insensitive
func testDeletedRecordsAreIgnored()
func testNextUpdateBeatsPreviousEvenWhenClockIsBehind() // previous = now + 300s → result > previous
func testNextUpdateUsesNowWhenAhead()               // previous = now - 60s → result == now
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CoreModelsTests` → compile failure.
- [ ] **Step 3: Implement.** Walk the parent chain with a visited set to stop on cycles.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(core): host inheritance, filtering and timestamps"` (add new files first).

---

### Task 3: Vault encryption

**Files:**
- Create: `Sources/SyncCore/VaultCrypto.swift`
- Test: `Tests/SyncCoreTests/VaultCryptoTests.swift`

**Interfaces:**
- Produces:
  - `enum VaultCrypto` with:
    - `static let defaultIterations = 600_000`
    - `static func randomSalt() -> Data` (16 bytes)
    - `static func newVaultKey() -> SymmetricKey` (256-bit)
    - `static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey` (PBKDF2-HMAC-SHA256 via `_CryptoExtras` `KDF.Insecure.PBKDF2`, 32-byte output)
    - `static func wrap(vaultKey: SymmetricKey, with: SymmetricKey) throws -> Data` (AES.GCM `combined`)
    - `static func unwrap(_ wrapped: Data, with: SymmetricKey) throws -> SymmetricKey` throws `VaultCryptoError.wrongPassphrase` on authentication failure
    - `static func seal(_ plaintext: Data, id: UUID, type: SyncRecordType, key: SymmetricKey) throws -> Data`
    - `static func open(_ ciphertext: Data, id: UUID, type: SyncRecordType, key: SymmetricKey) throws -> Data` throws `VaultCryptoError.tamperedRecord`
  - `enum VaultCryptoError: Error, Equatable { case wrongPassphrase, tamperedRecord }`

- [ ] **Step 1: Write the failing tests** (use `iterations: 1_000` for speed)

```swift
func testWrapUnwrapRoundTrip()                 // unwrap(wrap(k, pk), pk) has same bytes as k
func testWrongPassphraseThrows()               // derive with "wrong" → XCTAssertThrowsError(…) { XCTAssertEqual($0 as? VaultCryptoError, .wrongPassphrase) }
func testSameInputsDeriveSameKey()             // deterministic for passphrase+salt+iterations
func testSealOpenRoundTrip()
func testOpenFailsWhenIdOrTypeDiffers()        // sealed for (id1,.host), open with (id2,.host) and (id1,.snippet) → .tamperedRecord
func testSealingTwiceGivesDifferentCiphertext() // fresh nonce each time
func testCiphertextDoesNotContainPlaintext()   // seal "192.168.99.200"; ciphertext.range(of: Data("192.168".utf8)) == nil
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter VaultCryptoTests`.
- [ ] **Step 3: Implement.** If `KDF.Insecure.PBKDF2` isn't in the resolved swift-crypto version, bump the dependency minimum to the first version that has it and note the version in the commit.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): vault key derivation, wrapping and record sealing"`

---

### Task 4: Wire types and merge rule

**Files:**
- Create: `Sources/SyncCore/WireTypes.swift`, `Sources/SyncCore/MergeRule.swift`
- Test: `Tests/SyncCoreTests/MergeRuleTests.swift`, `Tests/SyncCoreTests/WireTypesTests.swift`

**Interfaces:**
- Produces (all `Codable, Equatable, Sendable`, encoded with `CoreJSON`):
  - `struct EncryptedRecord { id: UUID; type: SyncRecordType; updatedAt: Date; deleted: Bool; deviceID: String; seq: Int64?; ciphertext: Data }`
  - `struct VaultMetadata { vaultID: UUID; salt: Data; iterations: Int; wrappedKey: Data; version: Int /* 1 */ }`
  - `struct RecordsPage { records: [EncryptedRecord]; nextSince: Int64; hasMore: Bool }`
  - `struct UpsertRequest { records: [EncryptedRecord] }` / `struct UpsertResponse { records: [EncryptedRecord] }` (the server's resulting copy of each, with `seq`)
  - `struct RewrapRequest { oldWrappedKey: Data; salt: Data; iterations: Int; wrappedKey: Data }`
  - `enum MergeRule { static func incomingWins(_ incoming: (updatedAt: Date, deviceID: String), over existing: (updatedAt: Date, deviceID: String)) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
func testNewerTimestampWins()
func testOlderTimestampLoses()
func testTieBrokenByLargerDeviceID()   // same updatedAt: "mac-b" beats "mac-a"; "mac-a" does not beat "mac-b"
func testIdenticalRecordDoesNotWin()   // same updatedAt and deviceID → false (idempotent re-send)
func testEncryptedRecordJSONRoundTrip()
```

- [ ] **Step 2–4:** fail → implement → pass (`swift test --filter SyncCoreTests`).
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): wire types and last-writer-wins rule"`

---

### Task 5: Server skeleton, health and API keys

**Files:**
- Create: `Server/Package.swift`, `Sources/SyncServer/configure.swift`, `routes.swift`, `APIKeyMiddleware.swift`, `Sources/Run/main.swift`
- Test: `Server/Tests/SyncServerTests/AuthTests.swift`

**Interfaces:**
- Consumes: `SyncCore` via `.package(path: "../Packages/CoreSSH")`.
- Produces:
  - `func configure(_ app: Application, apiKeys: Set<String>, database: DatabaseConfigurationFactory) async throws` — registers migrations (Task 6/7), runs `autoMigrate`, installs routes. `main.swift` calls it with `APIKeyMiddleware.parse(Environment.get("SYNC_API_KEYS"))` and `.sqlite(.file(DATABASE_PATH))`; tests use `.sqlite(.memory)`.
  - `struct APIKeyMiddleware: AsyncMiddleware { static func parse(_ raw: String?) -> Set<String> }`
  - Route group `/v1` behind the middleware. Responses with `Content-Type: application/json`, error body `{"error": "<message>"}`.
  - Dependencies: `vapor/vapor` from 4.99.0, `vapor/fluent` from 4.9.0, `vapor/fluent-sqlite-driver` from 4.6.0. Server targets may use `swiftLanguageModes: [.v5]` if Vapor's Sendable checking blocks Swift 6 mode.

- [ ] **Step 1: Write the failing tests** (XCTVapor, in-memory DB, keys `["k1","k2"]`)

```swift
func testHealthNeedsNoAuth()          // GET /health → 200, body {"status":"ok"}
func testV1RejectsMissingKey()        // GET /v1/vault → 401
func testV1RejectsWrongKey()          // Bearer nope → 401
func testV1AcceptsEitherKey()         // Bearer k2 → not 401
func testParseTrimsAndDropsEmpties()  // parse(" a , ,b ") == ["a","b"]; parse(nil) == []
func testNoKeysConfiguredRejectsAll() // empty set → every /v1 call is 401
```

- [ ] **Step 2–4:** `cd Server && swift test` fail → implement → pass. (First build fetches Vapor; allow several minutes.)
- [ ] **Step 5: Commit** — `git commit -m "feat(server): Vapor skeleton with health check and API keys"`

---

### Task 6: Vault endpoints

**Files:**
- Create: `Sources/SyncServer/Models/VaultRow.swift`, `Migrations.swift` (CreateVault), `Controllers/VaultController.swift`
- Test: `Server/Tests/SyncServerTests/VaultTests.swift`

**Interfaces:**
- Consumes: `VaultMetadata`, `RewrapRequest`.
- Produces:
  - `GET /v1/vault` → 200 `VaultMetadata` or 404.
  - `PUT /v1/vault` (body `VaultMetadata`) → 201; 409 if a vault exists.
  - `POST /v1/vault/rewrap` (body `RewrapRequest`) → 200 updated `VaultMetadata` (same `vaultID`); 409 if `oldWrappedKey` ≠ stored; 404 if no vault.

- [ ] **Step 1: Write the failing tests**

```swift
func testGetVaultIs404BeforeSetup()
func testPutThenGetReturnsSameMetadata()
func testSecondPutIs409AndDoesNotOverwrite()
func testRewrapWithMatchingOldKeyUpdatesSaltAndKeyButKeepsVaultID()
func testRewrapWithStaleOldKeyIs409()
```

- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): vault metadata endpoints"`

---

### Task 7: Records endpoints

**Files:**
- Create: `Sources/SyncServer/Models/RecordRow.swift`, migration CreateRecords (columns per spec §7: id PK, type, updated_at, deleted, device_id, seq unique+indexed, ciphertext blob), `Controllers/RecordsController.swift`
- Test: `Server/Tests/SyncServerTests/RecordsTests.swift`

**Interfaces:**
- Consumes: `EncryptedRecord`, `RecordsPage`, `UpsertRequest`, `UpsertResponse`, `MergeRule`.
- Produces:
  - `POST /v1/records` (body `UpsertRequest`, max 500 records) → 200 `UpsertResponse`. In one transaction: for each record, if new or `MergeRule.incomingWins`, store it with `seq = currentMax + 1`; otherwise keep the stored row. Return the stored copy of every submitted id.
  - `GET /v1/records?since=<Int64, default 0>&limit=<Int, default 200, max 500>` → `RecordsPage` ordered by `seq` ascending, `seq > since`; `nextSince` = last returned seq (or `since` when empty); `hasMore` true when more rows exist.
  - Limits: request body max 10 MB (`app.routes.defaultMaxBodySize`); any single `ciphertext` over 1 MB → 413.

- [ ] **Step 1: Write the failing tests**

```swift
func testUpsertNewRecordAssignsSeq()                    // seq == 1, then 2 for the next
func testOlderUpdateIsIgnoredAndStoredCopyReturned()    // response holds the newer stored version, seq unchanged
func testNewerUpdateReplacesAndGetsNewSeq()
func testTombstoneIsStoredAndReturned()                 // deleted == true round-trips
func testResendingIdenticalRecordIsHarmless()           // same record twice → one row, seq unchanged
func testFetchSinceReturnsOnlyLaterRecordsInOrder()
func testPagingWithLimitSetsHasMoreAndNextSince()       // 5 records, limit 2 → pages of 2,2,1; hasMore true,true,false
func testLimitIsClampedTo500()                          // limit=100000 → no error, at most 500 returned
func testOversizedCiphertextIs413()                     // 2 MB ciphertext
func testMalformedJSONIs400()
func testMoreThan500RecordsInOneUpsertIs400()
```

- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): record upsert and incremental fetch"`

---

### Task 8: Sync engine

**Files:**
- Create: `Sources/SyncCore/SyncEngine.swift`
- Test: `Tests/SyncCoreTests/SyncEngineTests.swift` (with `InMemoryTransport` and `InMemoryStore` test doubles in `Tests/SyncCoreTests/Fakes.swift`; `InMemoryTransport` applies `MergeRule` and assigns seqs like the server)

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces:
  - `struct PlainRecord: Equatable, Sendable { id: UUID; type: SyncRecordType; updatedAt: Date; deleted: Bool; deviceID: String; payload: Data }` plus `init<M: SyncableModel>(_ model: M, deviceID: String) throws` and `func decode<M: SyncableModel>(_: M.Type) throws -> M`.
  - `protocol SyncTransport: Sendable { func getVault() async throws -> VaultMetadata?; func putVault(_: VaultMetadata) async throws; func rewrap(_: RewrapRequest) async throws -> VaultMetadata; func fetch(since: Int64, limit: Int) async throws -> RecordsPage; func upsert(_: [EncryptedRecord]) async throws -> [EncryptedRecord] }` — `putVault` throws `SyncError.vaultAlreadyExists` on 409.
  - `protocol SyncLocalStore: Sendable { func dirtyRecords() async throws -> [PlainRecord]; func markClean(_ ids: [UUID: Date]) async throws /* only if updatedAt still matches */; func apply(_ records: [PlainRecord]) async throws /* store applies MergeRule itself */; func markAllDirty() async throws; func removeAll() async throws; var syncState: SyncState { get async }; func setSyncState(_: SyncState) async throws }`
  - `struct SyncState: Codable, Equatable, Sendable { var vaultID: UUID?; var lastSeq: Int64 }`
  - `enum JoinMode: Sendable { case merge, replace }`
  - `enum SyncError: Error, Equatable { case wrongPassphrase, noVault, vaultAlreadyExists, vaultChanged, locked }`
  - `actor SyncEngine { init(transport: any SyncTransport, store: any SyncLocalStore, deviceID: String, iterations: Int = VaultCrypto.defaultIterations); func vaultExists() async throws -> Bool; func createVault(passphrase: String) async throws -> SymmetricKey; func join(passphrase: String, mode: JoinMode) async throws -> SymmetricKey; func unlock(with key: SymmetricKey) async; func changePassphrase(old: String, new: String) async throws; func sync() async throws -> SyncReport }`
  - `struct SyncReport: Equatable, Sendable { var pushed: Int; var pulled: Int }`
- Behavior:
  - `createVault`: random salt and vault key; `putVault`; set `syncState = (vaultID, 0)`; mark all local records dirty.
  - `join`: `getVault` (nil → `.noVault`); derive and unwrap (failure → `.wrongPassphrase`, **no store or server calls after that**); `.replace` → `store.removeAll()`; `.merge` → `markAllDirty()`; set `syncState = (vaultID, 0)`. Duplicate skipping on merge is milestone 4 (app store).
  - `sync()`: requires an unlocked key (`.locked`). `getVault`; if nil or its `vaultID` ≠ `syncState.vaultID` → throw `.vaultChanged` without pushing. Push: seal dirty records, `upsert` in batches of 500, `markClean` with each record's sent `updatedAt` only after the batch succeeds. Pull: page `fetch(since: lastSeq, limit: 500)` until `hasMore == false`, open each record, `apply`, save `lastSeq` after each page.
  - The app (milestone 4) handles `.vaultChanged` by asking Cory to re-create the vault from this Mac (`createVault` then full upload).

- [ ] **Step 1: Write the failing tests**

```swift
func testCreateVaultThenSyncPushesLocalRecords()       // store has 2 dirty → report.pushed == 2, transport holds 2 encrypted records
func testSecondDeviceJoinsAndPullsRecords()            // A creates+syncs; B joins(.merge) and syncs → B store has A's records, decoded equal
func testJoinWithWrongPassphraseThrowsAndTouchesNothing() // .wrongPassphrase; B store unchanged; transport upsert never called
func testJoinReplaceDiscardsLocalData()
func testJoinMergeUploadsLocalData()
func testEditOnOneDeviceReachesTheOther()             // A edits host (Timestamps.nextUpdate), sync A, sync B → B has edit
func testInterruptedPushLeavesRecordsDirty()           // transport upsert throws once → record still dirty; next sync pushes it; server has one copy
func testRecordEditedDuringPushStaysDirty()            // store changes updatedAt between dirtyRecords and markClean → stays dirty
func testVaultChangedIsDetected()                      // transport vault replaced (new vaultID) → sync throws .vaultChanged, nothing pushed
func testSyncWhileLockedThrows()
func testChangePassphraseKeepsDataReadable()           // change, then a fresh device joins with the new passphrase and decrypts; old passphrase → .wrongPassphrase
func testPullPagesUntilDone()                          // 1,200 records → all pulled, lastSeq == max seq
```

- [ ] **Step 2–4:** fail → implement → pass (`swift test --filter SyncEngineTests`, iterations 1,000 in tests).
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): sync engine with vault create, join and incremental sync"`

---

### Task 9: HTTP transport and end-to-end test against the real server

**Files:**
- Create: `Packages/CoreSSH/Sources/SyncCore/HTTPSyncTransport.swift`
- Test: `Server/Tests/SyncServerTests/EndToEndTests.swift`, `Packages/CoreSSH/Tests/SyncCoreTests/HTTPSyncTransportTests.swift`

**Interfaces:**
- Consumes: Task 8 protocols, Tasks 5–7 endpoints.
- Produces: `struct HTTPSyncTransport: SyncTransport { init(baseURL: URL, apiKey: String, session: URLSession = .shared) }`. Maps 401 → `SyncTransportError.unauthorized`, 404 on `GET /v1/vault` → `nil`, 409 on PUT → `SyncError.vaultAlreadyExists`, other non-2xx → `SyncTransportError.http(status: Int, message: String)`. Imports `FoundationNetworking` under `#if canImport(FoundationNetworking)`. A trailing slash on `baseURL` must not produce `//v1`.

- [ ] **Step 1: Write the failing tests**

```swift
// HTTPSyncTransportTests
func testURLJoiningHandlesTrailingSlash()   // "http://nas:8080/" and "http://nas:8080" both build "http://nas:8080/v1/records?since=0&limit=500"

// EndToEndTests — start the app with app.testable(method: .running(port: 0)) on an in-memory DB,
// two SyncEngines with in-memory stores (reuse the fake store, moved to a small `SyncTestSupport` test-helper target if needed)
func testTwoMacsSyncThroughRealServer()           // A creates vault, adds Host(address: "192.168.99.200"); B joins, syncs, sees it
func testServerStoresNoPlaintext()                // after sync, scan every RecordRow.ciphertext and VaultRow for "192.168.99.200", the host label and the password → none found
func testWrongAPIKeyFailsClearly()                // transport with bad key → SyncTransportError.unauthorized
```

- [ ] **Step 2–4:** fail → implement → pass (`cd Server && swift test --filter EndToEndTests`; `cd Packages/CoreSSH && swift test`).
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): HTTP transport and end-to-end tests"`

---

### Task 10: Docker packaging and server README

**Files:**
- Create: `Server/Dockerfile`, `Server/docker-compose.yml`, `Server/README.md`, `Server/.dockerignore`
- Modify: root `README.md` (link to `Server/README.md`)

**Interfaces:**
- Produces:
  - Multi-stage Dockerfile. The build context is the **repo root** (the server needs `Packages/CoreSSH`): build stage `swift:6.0-jammy` running `swift build -c release --static-swift-stdlib` in `Server/`; runtime stage `ubuntu:jammy` with only the binary, CA certificates and a non-root user; `EXPOSE 8080`; `HEALTHCHECK` hitting `/health`; `ENTRYPOINT ["./Run", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]`.
  - `docker-compose.yml`: service `termius-sync`, `build: { context: .., dockerfile: Server/Dockerfile }`, ports `8080:8080`, named volume `sync-data:/data`, env `SYNC_API_KEYS` and `DATABASE_PATH=/data/sync.sqlite`, `restart: unless-stopped`.
  - README: how to generate keys (`openssl rand -hex 32`), set them, run it, put it behind a reverse proxy for TLS, back up the volume.

- [ ] **Step 1: Verify the release build in the sandbox** — `cd Server && swift build -c release` → "Build complete!".
- [ ] **Step 2: Write the Docker files and README.**
- [ ] **Step 3: Cory verifies on the homelab** (the sandbox has no Docker):
  ```
  cd Server
  SYNC_API_KEYS=$(openssl rand -hex 32) docker compose up -d --build
  curl http://localhost:8080/health
  ```
  Expected: `{"status":"ok"}`.
- [ ] **Step 4: Commit** — `git commit -m "build(server): Dockerfile, compose file and setup guide"`
