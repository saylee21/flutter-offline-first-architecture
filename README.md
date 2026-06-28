# Flutter Offline-First Architecture

A documented reference architecture for building offline-first Flutter applications using Isar as the local source of truth, a background sync queue, and clean architecture with GetX.

Based on patterns shipped in a production agri marketplace used by farmers and distributors across Maharashtra.

---

## The Problem

Field workers in agriculture operate in connectivity dead zones — remote farms, warehouses on the outskirts, rural distribution centres. A typical workflow: check inventory, create an order, generate an invoice, upload a delivery photo. If the app requires internet at any step, the workflow breaks.

The app must:
- Work fully offline for hours at a time
- Queue every write operation (order, invoice, signature, photo)
- Sync in the background when connectivity returns
- Resolve conflicts when the same record was modified on another device
- Show the user what is synced, what is pending, and what failed

---

## Solution Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Presentation Layer                  │
│  GetX Controllers → Reactive bindings to UI             │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                     Domain Layer                        │
│  Use cases, business logic, validation                  │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                      Data Layer                         │
│  ┌─────────────────┐  ┌──────────────────────────────┐  │
│  │  IsarRepository │  │     RemoteRepository         │  │
│  │ (offline source)│  │     (API calls)              │  │
│  └────────┬────────┘  └──────────┬───────────────────┘  │
│           │                      │                      │
│  ┌────────▼──────────────────────▼───────────────────┐  │
│  │                  Sync Queue                       │  │
│  │  Pending operations → Retry logic → Conflict      │  │
│  │  resolution → Acknowledge                         │  │
│  └──────────────────────┬─────────────────────────── ┘  │
│                         │                               │
│  ┌──────────────────────▼────────────────────────────┐  │
│  │                  Background Worker                │  │
│  │  WorkManager / alarm clock → periodic sync        │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Architecture

```
lib/
├── core/
│   ├── local_db/
│   │   ├── isar_service.dart          ─ Database initialisation, schema registration
│   │   └── migrations.dart            ─ Schema versioning and data migrations
│   │
│   ├── sync/
│   │   ├── sync_queue.dart            ─ Queue for pending writes
│   │   ├── sync_processor.dart        ─ Processes queue items in order
│   │   ├── background_sync_worker.dart─ WorkManager / alarm manager integration
│   │   └── conflict_resolver.dart     ─ Last-write-wins / merge strategies
│   │
│   ├── network/
│   │   ├── api_client.dart            ─ Dio instance with interceptors
│   │   ├── connectivity_service.dart  ─ Monitors network state
│   │   └── retry_interceptor.dart     ─ Exponential backoff on failure
│   │
│   └── utils/
│       └── connectivity_controller.dart─ Reactive connection state via GetX
│
├── features/
│   ├── products/
│   │   ├── data/
│   │   │   ├── product_repository.dart       ─ Isar + remote implementation
│   │   │   └── product_sync_adapter.dart     ─ Queue-aware sync logic
│   │   ├── domain/
│   │   │   ├── product_controller.dart       ─ GetX controller
│   │   │   └── product_model.dart            ─ Isar-collected model
│   │   └── presentation/
│   │       └── product_list_page.dart
│   │
│   ├── orders/
│   │   ├── data/
│   │   │   ├── order_repository.dart
│   │   │   └── order_sync_adapter.dart
│   │   ├── domain/
│   │   │   └── order_controller.dart
│   │   └── presentation/
│   │       └── order_form_page.dart
│   │
│   └── invoices/
│       ├── data/
│       │   └── invoice_repository.dart
│       ├── domain/
│       │   └── invoice_controller.dart
│       └── presentation/
│           └── invoice_detail_page.dart
│
└── config/
    └── app_config.dart
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Local database | Isar | Fastest embedded DB for Flutter, reactive queries, ACID, supports complex filtering |
| State management | GetX | Controllers persist across navigation, built-in DI, minimal code overhead |
| Sync strategy | Operation queue | Each write is recorded as a sync operation; order is preserved |
| Conflict resolution | Last-write-wins + manual merge | For most agri data (prices, quantities), LWW is acceptable. For invoices, manual merge |
| Background sync | WorkManager | Android-native scheduling, respects Doze mode, supports periodic and one-shot work |
| Queue persistence | Isar (same instance) | No separate queue DB; operations stored as Isar collections with `isSynced` flag |

---

## Sync Queue Detail

### How Writes Flow

```
User action
    │
    ▼
Controller → calls use case
    │
    ▼
Repository → writes to Isar first (optimistic)
    │
    ▼
Repository → enqueues sync operation
    │
    ▼
SyncQueue → picks up pending operation
    │
    ▼
Is online? ──Yes──→ Execute API call
    │                    │
    No                   ├── Success → mark isSynced = true
    │                    └── Failure → increment retryCount, set nextRetryAt
    │
    ▼
Queue remains pending → retried on next sync cycle
```

### Sync Operation Schema

```dart
@collection
class SyncOperation {
  Id id = Isar.autoIncrement();
  late String entityType;            // 'order', 'invoice', 'product'
  late String operation;             // 'create', 'update', 'delete'
  late String entityId;              // local or remote ID
  late String payload;               // JSON serialised data
  late DateTime createdAt;
  String? parentOperationId;         // dependency link for child ops
  DateTime? lastAttemptAt;
  int retryCount = 0;
  bool isSynced = false;
  String? errorMessage;

  bool get hasDependency => parentOperationId != null;

  bool get shouldRetry {
    if (isSynced || retryCount >= 10) return false;
    if (lastAttemptAt == null) return true;
    final backoff = Duration(seconds: pow(2, retryCount).clamp(1, 1800).toInt());
    return DateTime.now().difference(lastAttemptAt!) >= backoff;
  }
}
```

### Background Sync Worker with WorkManager

```dart
class BackgroundSyncWorker {
  final SyncQueue _queue;
  final ApiClient _api;
  final Isar _isar;
  final ConnectivityService _connectivity;

  Future<void> registerPeriodicSync() async {
    await Workmanager().registerPeriodicTask(
      'periodicBackgroundSync',
      'periodicBackgroundSync',
      frequency: Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: Duration(seconds: 30),
    );
  }

  Future<void> registerImmediateSync() async {
    await Workmanager().registerOneOffTask(
      'immediateSync', 'immediateSync',
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  @pragma('vm:entry-point')
  static Future<void> callbackDispatcher() async {
    Workmanager().executeTask((task, inputData) async {
      final isar = await Isar.open([ProductSchema, OrderSchema, InvoiceSchema, SyncOperationSchema]);
      final queue = SyncQueue(isar);
      final api = ApiClient(baseUrl: '');
      final connectivity = ConnectivityService();
      final worker = BackgroundSyncWorker(queue, api, isar, connectivity);
      await worker.processAll();
      await isar.close();
      return true;
    });
  }

  Future<void> processAll() async {
    if (!await _connectivity.isConnected) return;
    final pending = await _queue.getPending();
    if (pending.isEmpty) return;

    for (final operation in pending) {
      if (!operation.shouldRetry) continue;
      try {
        await _executeOperation(operation);
        await _queue.markSynced(operation.id);
      } catch (e) {
        await _queue.markFailed(operation.id, e.toString());
      }
    }
  }
}
```

---

## Isar Schema Example

```dart
@collection
class Product {
  Id id = Isar.autoIncrement();
  late String remoteId;
  late String name;
  late String category;
  late double price;
  late String unit;                    // kg, dozen, quintal
  late int stockQuantity;
  late String? imagePath;
  late DateTime updatedAt;
  bool isSynced = false;

  @Index()
  late String category;

  @Index()
  late bool isSynced;
}
```

---

## Connectivity Handling

```dart
class ConnectivityController extends GetxController {
  final ConnectivityService _connectivity = ConnectivityService();
  RxBool isOnline = true.obs;

  @override
  void onInit() {
    super.onInit();
    _connectivity.onStatusChange.listen((status) {
      final wasOffline = !isOnline.value;
      isOnline.value = status == ConnectivityStatus.connected;
      if (wasOffline && isOnline.value) {
        Get.find<BackgroundSyncWorker>().processAll();
      }
    });
  }
}
```

---

## Hard Problems Solved

### 1. Partial Writes Without Compromise

When creating an order with photos, signatures, and line items — each piece could fail independently. Solution: stage the entire order in Isar first, then sync each component as separate queue operations with dependency tracking. The invoice is not marked synced until all child operations succeed.

### 2. Photo Uploads on Slow Networks

Images are resized locally (1024px max) before being queued. The worker uploads photos in background chunks with progress tracking visible to the user. Failed uploads retry with exponential backoff capped at 30 minutes.

### 3. Conflict Detection

When two devices modify the same product price offline, the first to sync wins. The second device receives a `409 Conflict` response. The local copy is kept as a "fork" and the user is prompted to accept or override.

---

---

## Directory Reference

- `lib/core/local_db/` — Isar service, schema migrations
- `lib/core/sync/` — Sync queue with dependency tracking, background worker with WorkManager
- `lib/features/` — Feature modules (products, orders, invoices) using clean architecture
- `architecture/` — System diagrams, Mermaid sequence charts
- `pubspec.yaml` — Dependency versions

---


## About

Built by [Saylee Bharsakle](https://saylee21.github.io). 3 years shipping Flutter apps in production across hospitality, agritech, insurance, and fintech.

Related: [flutter-matrix-webrtc-demo](https://github.com/saylee21/flutter-matrix-webrtc-demo)
