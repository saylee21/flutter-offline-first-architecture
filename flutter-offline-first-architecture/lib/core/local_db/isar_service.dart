class IsarService {
  late Isar _isar;
  final RxBool isInitialised = false.obs;
  static const int _targetSchemaVersion = 2;

  Future<void> init() async {
    _isar = await Isar.open(
      [
        ProductSchema,
        OrderSchema,
        InvoiceSchema,
        SyncOperationSchema,
      ],
      directory: await getApplicationDocumentsDirectory(),
      inspector: kDebugMode,
    );
    isInitialised.value = true;

    await _runMigrationsIfNeeded();
  }

  Isar get db => _isar;

  Future<void> _runMigrationsIfNeeded() async {
    final currentVersion = await _getSchemaVersion();

    if (currentVersion < 1) {
      await _migrateV0toV1();
    }
    if (currentVersion < 2) {
      await _migrateV1toV2();
    }

    if (currentVersion != _targetSchemaVersion) {
      await _setSchemaVersion(_targetSchemaVersion);
    }
  }

  Future<int> _getSchemaVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('isar_schema_version') ?? 0;
  }

  Future<void> _setSchemaVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('isar_schema_version', version);
  }

  Future<void> _migrateV0toV1() async {
    // v0 → v1: Add remoteId field to Order collection
    await _isar.writeTxn(() async {
      final orders = await _isar.orders.where().findAll();
      for (final order in orders) {
        if (order.remoteId.isEmpty) {
          order.remoteId = 'pending_${order.id}';
          await _isar.orders.put(order);
        }
      }
    });
  }

  Future<void> _migrateV1toV2() async {
    // v1 → v2: Add isDeleted flag for soft delete support
    // In Isar, schema changes require deleting or recreating the database.
    // This migration adds a soft delete field via SharedPreferences marker
    // and filters queries accordingly.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('soft_delete_enabled_v2', true);
  }

  Future<void> clearAll() async {
    await _isar.writeTxn(() async {
      await _isar.clear();
    });
  }

  Future<void> performTransaction<T>(Future<T> Function() callback) async {
    await _isar.writeTxn(() async {
      await callback();
    });
  }

  Future<bool> healthCheck() async {
    try {
      await _isar.writeTxn(() async {
        await _isar.syncOperations.count();
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> close() async {
    _isar.close();
  }
}
