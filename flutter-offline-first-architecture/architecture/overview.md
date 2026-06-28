# Architecture Overview

## System Flow

```mermaid
flowchart LR
    subgraph User["User Action"]
        A[Create Order\nUpload Photo\nSign Invoice]
    end

    subgraph App["Flutter App"]
        direction TB
        Ctrl[GetX Controller]
        UC[Use Case]
        DB[(Isar\nLocal DB)]
        Q[Sync Queue]
        W[Sync Worker]
    end

    subgraph Server["Backend API"]
        API[API Server]
    end

    A --> Ctrl
    Ctrl --> UC
    UC --> DB
    UC --> Q
    Q --> W
    W -->|online| API
    API -->|success| W
    W --> DB
```

## Write Flow (Offline)

```mermaid
sequenceDiagram
    participant U as User
    participant C as Controller
    participant R as Repository
    participant DB as Isar
    participant Q as SyncQueue
    participant W as SyncWorker
    participant API as Remote API

    U->>C: Create Order
    C->>R: createOrder(data)
    R->>DB: write order (isSynced=false)
    R->>Q: enqueue createOrder
    Q->>R: operation queued
    R->>C: order created (local ID)
    C->>U: Show "Pending" badge

    Note over U,API: User continues working offline

    Note over W: Background sync trigger (connectivity restored)

    W->>Q: getPending()
    Q->>W: [createOrder]
    W->>API: POST /orders
    API->>W: { id: "remote_123" }
    W->>DB: update local order with remoteId
    W->>Q: markSynced(order.id)
    Q->>DB: isSynced = true
    W->>U: Badge → "Synced"
```

## Read Flow (Offline)

```mermaid
sequenceDiagram
    participant U as User
    participant C as Controller
    participant R as Repository
    participant DB as Isar

    U->>C: View product list
    C->>R: getProducts()
    R->>DB: query all products
    DB->>R: [{...}, {...}]
    R->>C: products list
    C->>U: Render from local DB

    Note over U,DB: No network call. Isar is the source of truth.
    Note over C: If online, background refresh updates Isar.
```

## Conflict Resolution Flow

```mermaid
flowchart TD
    A[Device A modifies price offline] --> B{First to sync?}
    C[Device B modifies same price offline] --> B
    B -->|Device A| D[API accepts: price = Device A value]
    D --> E[Device B syncs: 409 Conflict]
    E --> F[UI shows "Conflict: price differs"]
    F --> G{User chooses}
    G -->|Keep theirs| H[Accept API value]
    G -->|Keep mine| I[Force push local value]
    H --> J[Resolved]
    I --> J
```

## Key Principles

1. **Local-first** — every write goes to Isar before anything else. The UI updates instantly regardless of network state.

2. **Queue-everything** — every write that needs to reach the server is recorded as a sync operation. No exceptions. Even if online, the write goes through the queue to ensure ordering.

3. **Ordered sync with dependency resolution** — operations are processed in order. If creating an order with photos, the order creation completes before photo uploads begin. The `parentOperationId` field enforces this.

4. **Exponential backoff** — failed operations retry at increasing intervals: 30s, 60s, 120s, 240s... capped at 30 minutes.

5. **Transparent status** — users see exactly what is synced (green), pending (yellow), or failed (red). The badge updates in real-time via GetX reactive state.

## Storage Architecture

```
┌──────────────────────────────────────────────────┐
│                   Isar Database                     │
│                                                     │
│  ┌──────────────┐  ┌──────────┐  ┌──────────────┐  │
│  │   Products    │  │  Orders   │  │   Invoices    │  │
│  │  ┌──────────┐ │  │ ┌──────┐ │  │ ┌──────────┐ │  │
│  │  │name      │ │  │ │items │ │  │ │signature  │ │  │
│  │  │price     │ │  │ │total │ │  │ │photos     │ │  │
│  │  │stock     │ │  │ │status│ │  │ │amount     │ │  │
│  │  │isSynced  │ │  │ │syncd │ │  │ │isSynced   │ │  │
│  │  └──────────┘ │  │ └──────┘ │  │ └──────────┘ │  │
│  └──────────────┘  └──────────┘  └──────────────┘  │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │           SyncOperations Queue                 │   │
│  │  ┌─────────┬──────────┬────────┬──────────┐   │   │
│  │  │entityId │ operation│ payload│parentOpId│   │   │
│  │  │order_42 │ create   │ {...}  │ null     │   │   │
│  │  │order_42 │ upload   │ {...}  │ order_42 │   │   │
│  │  └─────────┴──────────┴────────┴──────────┘   │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Schema Migrations

All schema changes are tracked via a version number stored in SharedPreferences. Each migration function handles one version transition:

| Version | Change |
|---------|--------|
| 0 | Initial schema |
| 1 | Add remoteId field to Order collection |
| 2 | Add soft delete support (isDeleted flag) |

## Tech Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Local Database | Isar 3.x | Fastest embedded DB for Flutter, reactive queries, ACID compliance |
| State Management | GetX | Controllers persist across navigation, built-in DI, minimal overhead |
| Background Sync | WorkManager | Android-native job scheduling, respects Doze mode |
| Network | Dio | Interceptors for retry logic, multipart upload support |
| Connectivity | connectivity_plus | Cross-platform network monitoring |
| Queue Persistence | Isar (same instance) | Operations stored as Isar collections, no separate queue system |
