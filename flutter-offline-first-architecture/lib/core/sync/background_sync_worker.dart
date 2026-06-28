import 'package:workmanager/workmanager.dart';

const String periodicSyncTask = 'periodicBackgroundSync';
const String oneShotSyncTask = 'immediateSync';

class BackgroundSyncWorker {
  final SyncQueue _queue;
  final ApiClient _api;
  final Isar _isar;
  final ConnectivityService _connectivity;
  final Rx<SyncStatus> status = SyncStatus.idle.obs;
  Timer? _retryTimer;
  int _consecutiveFailures = 0;
  static const int maxRetryIntervalSeconds = 1800;

  BackgroundSyncWorker(this._queue, this._api, this._isar, this._connectivity);

  Future<void> registerPeriodicSync() async {
    await Workmanager().registerPeriodicTask(
      periodicSyncTask,
      periodicSyncTask,
      frequency: Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: Duration(seconds: 30),
    );
  }

  Future<void> registerImmediateSync() async {
    await Workmanager().registerOneOffTask(
      oneShotSyncTask,
      oneShotSyncTask,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: Duration(seconds: 10),
    );
  }

  @pragma('vm:entry-point')
  static Future<void> callbackDispatcher() async {
    Workmanager().executeTask((task, inputData) async {
      final isar = await Isar.open(
        [ProductSchema, OrderSchema, InvoiceSchema, SyncOperationSchema],
      );
      final queue = SyncQueue(isar);
      final api = ApiClient(baseUrl: '');
      final connectivity = ConnectivityService();
      final worker = BackgroundSyncWorker(queue, api, isar, connectivity);
      await worker._executePendingOperations();
      await isar.close();
      return true;
    });
  }

  Future<void> processAll() async {
    if (!await _connectivity.isConnected) {
      status.value = SyncStatus.paused;
      return;
    }

    status.value = SyncStatus.syncing;
    await _executePendingOperations();
    status.value = SyncStatus.idle;
  }

  Future<void> _executePendingOperations() async {
    if (!await _connectivity.isConnected) return;

    final pending = await _queue.getPending();
    if (pending.isEmpty) return;

    _consecutiveFailures = 0;
    int successCount = 0;
    int failCount = 0;

    for (final operation in pending) {
      if (!await _connectivity.isConnected) break;
      if (!operation.shouldRetry) continue;

      try {
        await _executeOperation(operation);
        await _queue.markSynced(operation.id);
        successCount++;
        _consecutiveFailures = 0;
      } catch (e) {
        await _queue.markFailed(operation.id, e.toString());
        failCount++;
        _consecutiveFailures++;
      }
    }

    if (failCount > 0 && _consecutiveFailures < 10) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = Duration(
      seconds: (_consecutiveFailures * 30).clamp(30, maxRetryIntervalSeconds),
    );
    _retryTimer = Timer(delay, () {
      processAll();
    });
  }

  Future<void> _executeOperation(SyncOperation operation) async {
    switch (operation.entityType) {
      case 'product':
        await _syncProduct(operation);
        break;
      case 'order':
        await _syncOrder(operation);
        break;
      case 'invoice':
        await _syncInvoice(operation);
        break;
    }
  }

  Future<void> _syncProduct(SyncOperation op) async {
    switch (op.operation) {
      case 'create':
        await _api.post('/products', op.payload);
        break;
      case 'update':
        await _api.put('/products/${op.entityId}', op.payload);
        break;
      case 'delete':
        await _api.delete('/products/${op.entityId}');
        break;
    }
  }

  Future<void> _syncOrder(SyncOperation op) async {
    switch (op.operation) {
      case 'create':
        final response = await _api.post('/orders', op.payload);
        final remoteId = response['id'] as String;

        await _isar.writeTxn(() async {
          final localOrder = await _isar.orders.get(op.entityId);
          if (localOrder != null) {
            localOrder.remoteId = remoteId;
            localOrder.isSynced = true;
            await _isar.orders.put(localOrder);
          }
        });

        await _queue.markSynced(op.id);
        break;

      case 'update':
        await _api.put('/orders/${op.entityId}', op.payload);
        break;
    }
  }

  Future<void> _syncInvoice(SyncOperation op) async {
    final formData = FormData.fromMap({
      ...op.payload,
      if (op.payload.containsKey('imagePath'))
        'image': await MultipartFile.fromFile(
          op.payload['imagePath'] as String,
        ),
    });
    await _api.post('/invoices', formData);
  }

  Stream<int> observeProgress() {
    return _queue.observePendingCount();
  }

  Future<void> cancelScheduledSync() async {
    _retryTimer?.cancel();
    await Workmanager().cancelByUniqueName(periodicSyncTask);
  }

  void dispose() {
    _retryTimer?.cancel();
  }
}
