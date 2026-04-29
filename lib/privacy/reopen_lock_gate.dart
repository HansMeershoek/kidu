import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'reopen_lock_service.dart';

class ReopenLockGate extends StatefulWidget {
  const ReopenLockGate({
    super.key,
    required this.child,
    this.service,
    this.shouldLock,
    this.onLogout,
    this.gracePeriod = const Duration(seconds: 60),
  });

  final Widget child;
  final ReopenLockService? service;
  final FutureOr<bool> Function()? shouldLock;
  final Future<void> Function()? onLogout;
  final Duration gracePeriod;

  @override
  State<ReopenLockGate> createState() => _ReopenLockGateState();
}

class _ReopenLockGateState extends State<ReopenLockGate>
    with WidgetsBindingObserver {
  late final ReopenLockService _service = widget.service ?? ReopenLockService();

  DateTime? _backgroundedAt;
  StreamSubscription<User?>? _authSubscription;
  bool? _lastSignedIn;
  bool _coldStartChecked = false;
  bool _authTransitionHold = false;
  bool _locked = false;
  bool _authInFlight = false;
  bool _logoutInProgress = false;
  int _authTransitionCheckId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
      _handleAuthStateChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_handleColdStart());
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authInFlight || _authTransitionHold) {
      return;
    }

    if (state == AppLifecycleState.resumed) {
      unawaited(_handleResume());
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _backgroundedAt ??= DateTime.now();
    }
  }

  void _handleAuthStateChanged(User? user) {
    final signedIn = user != null;
    final wasSignedIn = _lastSignedIn;
    _lastSignedIn = signedIn;

    if (!signedIn) {
      _authTransitionCheckId++;
      if (_logoutInProgress) {
        return;
      }
      if (mounted) {
        setState(() {
          _authTransitionHold = false;
          _locked = false;
          _authInFlight = false;
        });
      }
      return;
    }

    if (wasSignedIn == false) {
      unawaited(_handleSignedInTransition());
    }
  }

  Future<void> _handleColdStart() async {
    final shouldShowLock = await _shouldShowLock();

    if (!mounted || !shouldShowLock) {
      if (mounted) {
        setState(() => _coldStartChecked = true);
      }
      return;
    }

    _showLockAndPrompt(coldStartChecked: true);
  }

  Future<void> _handleSignedInTransition() async {
    if (_authTransitionHold || _locked || _authInFlight) {
      return;
    }

    final checkId = ++_authTransitionCheckId;
    setState(() => _authTransitionHold = true);

    final shouldShowLock = await _shouldShowLock();
    if (!mounted || checkId != _authTransitionCheckId) {
      return;
    }

    if (!shouldShowLock) {
      setState(() => _authTransitionHold = false);
      return;
    }

    _showLockAndPrompt(clearAuthTransitionHold: true);
  }

  Future<void> _handleResume() async {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;

    if (backgroundedAt == null) {
      return;
    }

    final wasAwayFor = DateTime.now().difference(backgroundedAt);
    if (wasAwayFor < widget.gracePeriod) {
      return;
    }

    final shouldShowLock = await _shouldShowLock();

    if (!mounted || !shouldShowLock) {
      return;
    }

    _showLockAndPrompt();
  }

  Future<bool> _shouldShowLock() async {
    try {
      final enabled = await _service.loadEnabled();
      return enabled && await _shouldLock();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _shouldLock() async {
    return Future<bool>.value(widget.shouldLock?.call() ?? true);
  }

  void _showLockAndPrompt({
    bool coldStartChecked = false,
    bool clearAuthTransitionHold = false,
  }) {
    if (_locked) {
      return;
    }

    setState(() {
      if (coldStartChecked) {
        _coldStartChecked = true;
      }
      if (clearAuthTransitionHold) {
        _authTransitionHold = false;
      }
      _locked = true;
      _authInFlight = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_authenticateFromLock(alreadyMarkedInFlight: true));
      }
    });
  }

  Future<void> _authenticateFromLock({
    bool alreadyMarkedInFlight = false,
  }) async {
    if (_authInFlight && !alreadyMarkedInFlight) {
      return;
    }

    if (!alreadyMarkedInFlight) {
      setState(() => _authInFlight = true);
    }
    final result = await _service.authenticate();

    if (!mounted) {
      return;
    }

    if (result.status == ReopenLockAuthStatus.cancelled) {
      setState(() => _authInFlight = false);
      return;
    }

    setState(() {
      _authTransitionCheckId++;
      _authTransitionHold = false;
      _locked = false;
      _authInFlight = false;
    });
  }

  Future<void> _logout() async {
    if (_logoutInProgress) {
      return;
    }

    setState(() {
      _logoutInProgress = true;
      _authInFlight = false;
    });

    try {
      if (widget.onLogout != null) {
        await widget.onLogout!();
      }
    } finally {
      if (mounted) {
        setState(() {
          _authTransitionHold = false;
          _logoutInProgress = false;
          _locked = false;
          _authInFlight = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_coldStartChecked) {
      return const _ReopenLockHoldScreen();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_authTransitionHold)
          const Positioned.fill(child: _ReopenLockHoldScreen()),
        if (_locked)
          Positioned.fill(
            child: _authInFlight
                ? const _ReopenLockHoldScreen()
                : _ReopenLockScreen(
                    onRetry: _authenticateFromLock,
                    onLogout: _logout,
                  ),
          ),
        if (_logoutInProgress)
          const Positioned.fill(child: _ReopenLockHoldScreen()),
      ],
    );
  }
}

class _ReopenLockHoldScreen extends StatelessWidget {
  const _ReopenLockHoldScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Theme.of(context).scaffoldBackgroundColor);
  }
}

class _ReopenLockScreen extends StatelessWidget {
  const _ReopenLockScreen({required this.onRetry, required this.onLogout});

  final VoidCallback onRetry;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 28,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'KiDu is vergrendeld',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ontgrendel om verder te gaan.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.68),
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('Opnieuw proberen'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: onLogout,
                        child: const Text('Uitloggen'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
