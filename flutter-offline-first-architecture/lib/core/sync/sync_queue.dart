class SyncOperation {
  final String id;
  final String entityType;
  final String operation;
  final String entityId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final String? parentOperationId;
  DateTime? lastAttemptAt;
  int retryCount;
  bool isSynced;
  String? errorMessage;

  SyncOperation({
    required this.id,
    required this.entityType,
    required this.operation,
    required this.entityId,
    required this.payload,
    required this.createdAt,
    this.parentOperationId,
    this.lastAttemptAt,
    this.retryCount = 0,
    this.isSynced = false,
    this.errorMessage,
  });

  bool get hasDependency => parentOperationId != null;

  bool get isStale =>
      !isSynced && createdAt.isBefore(DateTime.now().subtract(Duration(days: 7)));

  bool get shouldRetry {
    if (isSynced || retryCount >= 10) return false;
    if (lastAttemptAt == null) return true;

    final backoff = Duration(
      seconds: pow(2, retryCount).clamp(1, 1800).toInt(),
    );
    return DateTime.now().difference(lastAttemptAt!) >= backoff;
  }
}

class SyncQueue {
  final Isar _isar;
  final RxInt pendingCount = 0.obs;
  final Rx<SyncStatus> status = SyncStatus.idle.obs;

  SyncQueue(this._isar);

  Future<void> enqueue(SyncOperation operation) async {
    await _isar.writeTxn(() async {
      await _isar.syncOperations.put(operation);
    });
    pendingCount.value++;
  }

  Future<List<SyncOperation>> getPending() async {
    final all = await _isar.syncOperations
        .filter()
        .isSyncedEqualTo(false)
        .isStaleEqualTo(false)
        .findAll();

    return all.where((op) => _isDependencySatisfied(op, all)).toList();
  }

  bool _isDependencySatisfied(
    SyncOperation operation,
    List<SyncOperation> all,
  ) {
    if (!operation.hasDependency) return true;

    return all.any((other) =>
        other.id == operation.parentOperationId && other.isSynced);
  }

  Future<void> enqueueBatch(List<SyncOperation> operations) async {
    await _isar.writeTxn(() async {
      for (final op in operations) {
        await _isar.syncOperations.put(op);
      }
    });
    pendingCount.value = await _isar.syncOperations
        .filter()
        .isSyncedEqualTo(false)
        .count();
  }

  Future<void> markSynced(String operationId) async {
    await _isar.writeTxn(() async {
      final op = await _isar.syncOperations.get(operationId);
      if (op != null) {
        op.isSynced = true;
        await _isar.syncOperations.put(op);
      }
    });
    await _recount();
  }

  Future<void> markFailed(String operationId, String error) async {
    await _isar.writeTxn(() async {
      final op = await _isar.syncOperations.get(operationId);
      if (op != null) {
        op.retryCount++;
        op.lastAttemptAt = DateTime.now();
        op.errorMessage = error;
        await _isar.syncOperations.put(op);
      }
    });
  }

  Future<void> markAllFailed(String error) async {
    final pending = await getPending();
    for (final op in pending) {
      await markFailed(op.id, error);
    }
  }

  Future<List<SyncOperation>> getStale() async {
    return await _isar.syncOperations
        .filter()
        .isSyncedEqualTo(false)
        .staleEqualTo(true)
        .findAll();
  }

  Future<int> count() async {
    return await _isar.syncOperations
        .filter()
        .isSyncedEqualTo(false)
        .count();
  }

  Future<void> _recount() async {
    pendingCount.value = await _isar.syncOperations
        .filter()
        .isSyncedEqualTo(false)
        .count();
  }

  Stream<int> observePendingCount() {
    return Stream.periodic(Duration(seconds: 5), (_) => pendingCount.value);
  }
}

enum SyncStatus { idle, syncing, failed, paused }
