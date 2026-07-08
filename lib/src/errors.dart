import 'package:flutter/services.dart';

enum SecureVideoErrorCode {
  invalidKey,
  fileNotFound,
  corruptStream,
  adapterNotRegistered,
  drmError,
  platformNotSupported,
  disposed,
  unknown;

  static SecureVideoErrorCode fromWire(String? code) =>
      SecureVideoErrorCode.values.asNameMap()[code] ??
      SecureVideoErrorCode.unknown;
}

class SecureVideoException implements Exception {
  SecureVideoException(this.code, this.message);

  SecureVideoException.fromPlatform(PlatformException e)
      : code = SecureVideoErrorCode.fromWire(e.code),
        message = e.message ?? e.code;

  final SecureVideoErrorCode code;
  final String message;

  @override
  String toString() => 'SecureVideoException(${code.name}): $message';
}
