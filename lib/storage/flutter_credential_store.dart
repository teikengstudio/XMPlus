import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';
import "../services/app_log.dart";

/// The only credential adapter which depends on Flutter platform channels.
class FlutterCredentialStore implements CredentialStore {
  FlutterCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage() {
    AppLog.instance.trace(
      "lib/storage/flutter_credential_store.dart::FlutterCredentialStore.new",
    );
  }

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) {
    AppLog.instance.trace(
      "lib/storage/flutter_credential_store.dart::FlutterCredentialStore.read",
    );
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) {
    AppLog.instance.trace(
      "lib/storage/flutter_credential_store.dart::FlutterCredentialStore.write",
    );
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) {
    AppLog.instance.trace(
      "lib/storage/flutter_credential_store.dart::FlutterCredentialStore.delete",
    );
    return _storage.delete(key: key);
  }
}
