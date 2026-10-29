import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// The executable and language models must match trusted build-time hashes.
class OcrIntegrity {
  // The pinned, statically linked engine is built from Tesseract 5.5.4.
  static const windowsEngineHash =
      '0b6670e056c54dc8de074d6916fbefdc59545a3537d03341e3174f2f30f7c0bd';
  static const modelHashes = <String, String>{
    'eng': '7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2',
    'heb': '11f9e43ab227f786352a50f75c94c2e9906f1baba86d93276da19da7ce0904db',
    'rus': 'e16e5e036cce1d9ec2b00063cf8b54472625b9e14d893a169e2b0dedeb4df225',
  };

  static bool matchesBytes(List<int> bytes, String expectedHash) =>
      expectedHash.isNotEmpty &&
      sha256.convert(bytes).toString() == expectedHash;

  static Future<bool> matchesFile(File file, String expectedHash) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      return matchesBytes(await file.readAsBytes(), expectedHash);
    } on FileSystemException {
      return false;
    }
  }

  /// On Windows keep verified files open without write or delete sharing until
  /// the child exits. This prevents replacing the checked files before use.
  static Future<T> withLockedFiles<T>(
    List<File> files,
    Future<T> Function() action,
  ) async {
    if (!Platform.isWindows) return action();
    final library = DynamicLibrary.open('kernel32.dll');
    final createFile = library
        .lookupFunction<
          IntPtr Function(
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Uint32,
            Uint32,
            IntPtr,
          ),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    final closeHandle = library
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    final handles = <int>[];
    try {
      for (final file in files) {
        final path = file.absolute.path.toNativeUtf16();
        try {
          const genericRead = 0x80000000;
          const shareRead = 1;
          const openExisting = 3;
          const normalAndOpenReparsePoint = 0x80 | 0x00200000;
          final handle = createFile(
            path,
            genericRead,
            shareRead,
            nullptr,
            openExisting,
            normalAndOpenReparsePoint,
            0,
          );
          if (handle == -1) throw const OcrUnavailableException();
          handles.add(handle);
        } finally {
          calloc.free(path);
        }
      }
      return await action();
    } finally {
      for (final handle in handles.reversed) {
        closeHandle(handle);
      }
    }
  }

  /// Start a verified program, drain both pipes, and kill it on timeout.
  static Future<String?> runProcess(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final process = await Process.start(executable, args, runInShell: false);
    final output = StringBuffer();
    final outputDone = Completer<void>();
    final errorDone = Completer<void>();
    final stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          output.write,
          onDone: outputDone.complete,
          onError: (Object error, StackTrace stackTrace) =>
              outputDone.complete(),
        );
    final stderrSubscription = process.stderr.listen(
      (_) {},
      onDone: errorDone.complete,
      onError: (Object error, StackTrace stackTrace) => errorDone.complete(),
    );
    try {
      final results = await Future.wait<Object?>([
        process.exitCode,
        outputDone.future,
        errorDone.future,
      ]).timeout(timeout);
      return results.first == 0 ? output.toString() : null;
    } on TimeoutException {
      process.kill();
      // Keep the caller's file locks until the child actually exits, including
      // the case where it exited concurrently with the timeout.
      await process.exitCode;
      return null;
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
  }
}

/// A missing or altered offline OCR component must never be executed.
class OcrUnavailableException implements Exception {
  const OcrUnavailableException();
}
