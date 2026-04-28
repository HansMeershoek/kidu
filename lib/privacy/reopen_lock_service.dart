import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReopenLockAuthStatus {
  authenticated,
  cancelled,
  unsupported,
  technicalFailure,
}

class ReopenLockAuthResult {
  const ReopenLockAuthResult._(this.status, [this.error]);

  const ReopenLockAuthResult.authenticated()
    : this._(ReopenLockAuthStatus.authenticated);

  const ReopenLockAuthResult.cancelled([Object? error])
    : this._(ReopenLockAuthStatus.cancelled, error);

  const ReopenLockAuthResult.unsupported([Object? error])
    : this._(ReopenLockAuthStatus.unsupported, error);

  const ReopenLockAuthResult.technicalFailure([Object? error])
    : this._(ReopenLockAuthStatus.technicalFailure, error);

  final ReopenLockAuthStatus status;
  final Object? error;

  bool get isAuthenticated => status == ReopenLockAuthStatus.authenticated;

  bool get canFailOpen =>
      status == ReopenLockAuthStatus.unsupported ||
      status == ReopenLockAuthStatus.technicalFailure;
}

class ReopenLockService {
  ReopenLockService({
    LocalAuthentication? localAuthentication,
    Future<SharedPreferences> Function()? preferencesFactory,
  }) : _localAuthentication = localAuthentication ?? LocalAuthentication(),
       _preferencesFactory =
           preferencesFactory ?? SharedPreferences.getInstance;

  static const String enabledKey = 'privacy.reopenLockEnabled';

  final LocalAuthentication _localAuthentication;
  final Future<SharedPreferences> Function() _preferencesFactory;

  Future<bool> loadEnabled() async {
    final preferences = await _preferencesFactory();
    return preferences.getBool(enabledKey) ?? false;
  }

  Future<void> saveEnabled(bool enabled) async {
    final preferences = await _preferencesFactory();
    await preferences.setBool(enabledKey, enabled);
  }

  Future<bool> isDeviceAuthSupported() async {
    try {
      return _localAuthentication.isDeviceSupported();
    } on LocalAuthException catch (error) {
      _debugLog('Device auth support check failed: $error');
      return false;
    } catch (error) {
      _debugLog('Unexpected device auth support check failure: $error');
      return false;
    }
  }

  Future<ReopenLockAuthResult> authenticate({
    String localizedReason = ' ',
  }) async {
    try {
      final authenticated = await _localAuthentication.authenticate(
        localizedReason: localizedReason,
        biometricOnly: false,
      );

      if (authenticated) {
        return const ReopenLockAuthResult.authenticated();
      }

      return const ReopenLockAuthResult.cancelled();
    } on LocalAuthException catch (error) {
      _debugLog('Device auth failed: $error');
      return _resultForLocalAuthException(error);
    } catch (error) {
      _debugLog('Unexpected device auth failure: $error');
      return ReopenLockAuthResult.technicalFailure(error);
    }
  }

  ReopenLockAuthResult _resultForLocalAuthException(LocalAuthException error) {
    switch (error.code) {
      case LocalAuthExceptionCode.userCanceled:
      case LocalAuthExceptionCode.systemCanceled:
      case LocalAuthExceptionCode.timeout:
        return ReopenLockAuthResult.cancelled(error);
      case LocalAuthExceptionCode.noCredentialsSet:
      case LocalAuthExceptionCode.noBiometricsEnrolled:
      case LocalAuthExceptionCode.noBiometricHardware:
        return ReopenLockAuthResult.unsupported(error);
      case LocalAuthExceptionCode.authInProgress:
      case LocalAuthExceptionCode.uiUnavailable:
      case LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
      case LocalAuthExceptionCode.temporaryLockout:
      case LocalAuthExceptionCode.biometricLockout:
      case LocalAuthExceptionCode.userRequestedFallback:
      case LocalAuthExceptionCode.deviceError:
      case LocalAuthExceptionCode.unknownError:
        return ReopenLockAuthResult.technicalFailure(error);
    }
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint('[ReopenLockService] $message');
    }
  }
}
