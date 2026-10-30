import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

/// A self-contained encrypted diary. Backup files have exactly the same format
/// and can therefore be moved between devices without a server. Existing
/// backups from other supported versions remain readable.
///
/// The passphrase is never persisted. Call [lock] when the diary should no
/// longer be accessible. The caller must await each operation before starting
/// another operation on the same Vault instance.
class Vault {
  Vault(this.file);

  static const int _iterations = 310000;
  static const _version = 1;
  static final _cipher = AesGcm.with256bits();
  static final _aad = utf8.encode('finance-diary-vault-v1');

  final File file;
  SecretKey? _key;
  List<int>? _salt;
  int? _keyIterations;

  static Future<Vault> openDefault() async {
    final directory = await getApplicationSupportDirectory();
    if (Platform.isWindows) {
      final roamingPath = await _windowsRoamingAppData();
      if (roamingPath == null || roamingPath.isEmpty) {
        throw StateError(
          'Cannot find the Windows roaming application data folder.',
        );
      }
      return selectWindowsLocation(
        roamingDirectory: Directory(roamingPath),
        currentDirectory: directory,
      );
    }
    return Vault(File('${directory.path}${Platform.pathSeparator}diary.vault'));
  }

  // FOLDERID_RoamingAppData. The package's non-FFI analyzer stub does not
  // expose WindowsKnownFolder constants, although the runtime implementation
  // accepts the same documented GUID on Windows.
  static Future<String?> _windowsRoamingAppData() =>
      PathProviderWindows().getPath('{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}');

  /// Keep the pre-rebrand Windows location stable across product metadata
  /// changes. A diary created at the newer location is also recognized.
  /// Conflicting diaries are never overwritten or chosen silently.
  static Future<Vault> selectWindowsLocation({
    required Directory roamingDirectory,
    required Directory currentDirectory,
  }) async {
    final separator = Platform.pathSeparator;
    final legacy = File(
      '${roamingDirectory.path}${separator}com.example${separator}finance_diary${separator}diary.vault',
    );
    final current = File('${currentDirectory.path}${separator}diary.vault');
    if (legacy.absolute.path.toLowerCase() ==
        current.absolute.path.toLowerCase()) {
      return Vault(legacy);
    }
    final oldExists = await legacy.exists();
    final currentExists = await current.exists();
    if (oldExists && currentExists) {
      final oldHash = await digest.sha256.bind(legacy.openRead()).first;
      final currentHash = await digest.sha256.bind(current.openRead()).first;
      final equal =
          oldHash.bytes.length == currentHash.bytes.length &&
          List.generate(
            oldHash.bytes.length,
            (i) => i,
          ).every((i) => oldHash.bytes[i] == currentHash.bytes[i]);
      if (!equal) throw VaultLocationConflict(legacy: legacy, current: current);
    }
    if (oldExists || !currentExists) return Vault(legacy);
    return Vault(current);
  }

  Future<bool> exists() => file.exists();
  bool get isUnlocked => _key != null;

  /// Creates a new vault, refusing to overwrite an existing diary.
  Future<void> create(String passcode, Map<String, dynamic> initialData) async {
    if (await exists()) throw StateError('A diary already exists.');
    if (passcode.length < 8) {
      throw ArgumentError('The passcode must contain at least 8 characters.');
    }
    final salt = _randomBytes(16);
    final key = await _derive(passcode, salt, _iterations);
    final bytes = await _encrypt(initialData, key, salt, _iterations);
    await _write(bytes);
    _key = key;
    _salt = salt;
    _keyIterations = _iterations;
  }

  /// Throws [VaultException] for an incorrect passcode or damaged vault.
  Future<Map<String, dynamic>> unlock(String passcode) async {
    final opened = await _decrypt(await file.readAsBytes(), passcode);
    _key?.destroy();
    _key = opened.key;
    _salt = opened.salt;
    _keyIterations = opened.iterations;
    return opened.data;
  }

  Future<void> save(Map<String, dynamic> data) async {
    final key = _key;
    final salt = _salt;
    final iterations = _keyIterations;
    if (key == null || salt == null || iterations == null) {
      throw StateError('The diary is locked.');
    }
    await _write(await _encrypt(data, key, salt, iterations));
  }

  /// Copies the encrypted vault; this never writes plaintext to the backup.
  /// Use this for platform document pickers that accept bytes rather than a
  /// filesystem path when a platform picker supplies bytes instead.
  Future<List<int>> exportBytes() async {
    if (!isUnlocked) throw StateError('The diary is locked.');
    return file.readAsBytes();
  }

  Future<void> exportBackup(String destinationPath) async {
    final destination = File(destinationPath);
    if (destination.absolute.path == file.absolute.path) {
      throw ArgumentError('Backup destination must differ from the diary.');
    }
    await destination.writeAsBytes(await exportBytes(), flush: true);
  }

  /// Validates and decrypts a backup before replacing the current diary.
  /// Returns its contents and leaves it unlocked with its original passcode.
  Future<Map<String, dynamic>> restoreBackup(
    String backupPath,
    String passcode,
  ) async => restoreBytes(await File(backupPath).readAsBytes(), passcode);

  Future<Map<String, dynamic>> restoreBytes(
    List<int> bytes,
    String passcode,
  ) async {
    final opened = await _decrypt(bytes, passcode);
    await _write(bytes);
    _key?.destroy();
    _key = opened.key;
    _salt = opened.salt;
    _keyIterations = opened.iterations;
    return opened.data;
  }

  void lock() {
    _key?.destroy();
    _key = null;
    _salt = null;
    _keyIterations = null;
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static Future<SecretKey> _derive(
    String passcode,
    List<int> salt,
    int iterations,
  ) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(passcode)), nonce: salt);

  static Future<List<int>> _encrypt(
    Map<String, dynamic> data,
    SecretKey key,
    List<int> salt,
    int iterations,
  ) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: key,
      nonce: _randomBytes(12),
      aad: _aad,
    );
    return utf8.encode(
      jsonEncode({
        'version': _version,
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': iterations,
        'salt': base64Encode(salt),
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'tag': base64Encode(box.mac.bytes),
      }),
    );
  }

  static Future<_OpenedVault> _decrypt(List<int> bytes, String passcode) async {
    try {
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (envelope['version'] != _version ||
          envelope['kdf'] != 'PBKDF2-HMAC-SHA256') {
        throw const FormatException('Unsupported vault format.');
      }
      final iterations = envelope['iterations'] as int;
      // Prevent malformed backup files from causing unbounded work.
      if (iterations < 100000 || iterations > 1000000) {
        throw const FormatException('Invalid KDF parameters.');
      }
      final salt = base64Decode(envelope['salt'] as String);
      final nonce = base64Decode(envelope['nonce'] as String);
      final tag = base64Decode(envelope['tag'] as String);
      if (salt.length != 16 || nonce.length != 12 || tag.length != 16) {
        throw const FormatException('Invalid vault parameters.');
      }
      final key = await _derive(passcode, salt, iterations);
      final clear = await _cipher.decrypt(
        SecretBox(
          base64Decode(envelope['ciphertext'] as String),
          nonce: nonce,
          mac: Mac(tag),
        ),
        secretKey: key,
        aad: _aad,
      );
      final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      return _OpenedVault(key, salt, iterations, data);
    } on Object {
      throw const VaultException();
    }
  }

  Future<void> _write(List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }
}

class VaultException implements Exception {
  const VaultException();

  @override
  String toString() => 'Incorrect passcode or damaged diary.';
}

/// Two distinct Windows diaries exist; the UI must ask the user which to open.
class VaultLocationConflict implements Exception {
  const VaultLocationConflict({required this.legacy, required this.current});
  final File legacy;
  final File current;
  @override
  String toString() => 'Two different local diaries were found.';
}

class _OpenedVault {
  const _OpenedVault(this.key, this.salt, this.iterations, this.data);
  final SecretKey key;
  final List<int> salt;
  final int iterations;
  final Map<String, dynamic> data;
}
