import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase_options.dart';

/// Maps exceptions to user-friendly Dutch messages. Does not throw.
String mapUserFacingError(Object e,
    {String fallback = 'Er ging iets mis. Probeer opnieuw.'}) {
  try {
    if (e is FirebaseException) {
      final code = e.code;
      if (code == 'permission-denied' ||
          (code.endsWith('/permission-denied'))) {
        return 'Je hebt hiervoor geen toegang.';
      }
      if (code == 'unavailable') {
        return 'Geen verbinding met server. Probeer opnieuw.';
      }
      if (code == 'network-request-failed') {
        return 'Netwerkfout. Controleer je verbinding.';
      }
      if (code == 'failed-precondition') {
        return 'Actie kan nu niet worden uitgevoerd.';
      }
    }
    if (e is StateError) {
      final msg = e.message;
      if (msg.trim().isNotEmpty) {
        return msg.trim();
      }
    }
  } catch (_) {
    // Mapper must not throw
  }
  return fallback;
}

/// Typed result for the private note edit dialog. No Firestore in dialog.
sealed class PrivateNoteDialogResult {}

class PrivateNoteDialogCancelled extends PrivateNoteDialogResult {}

class PrivateNoteDialogDelete extends PrivateNoteDialogResult {}

class PrivateNoteDialogSave extends PrivateNoteDialogResult {
  PrivateNoteDialogSave(this.note);
  final String note;
}

class _PrivateNoteDialogContent extends StatefulWidget {
  const _PrivateNoteDialogContent({
    required this.initialNote,
    required this.hasInitialNote,
  });

  final String initialNote;
  final bool hasInitialNote;

  @override
  State<_PrivateNoteDialogContent> createState() =>
      _PrivateNoteDialogContentState();
}

class _PrivateNoteDialogContentState extends State<_PrivateNoteDialogContent> {
  late String _draftNote;
  bool _didPop = false;

  void _safePop(PrivateNoteDialogResult result) {
    if (_didPop) return;
    _didPop = true;
    Navigator.of(context, rootNavigator: false).pop(result);
  }

  @override
  void initState() {
    super.initState();
    _draftNote = widget.initialNote;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Notitie bewerken'),
      content: TextFormField(
        initialValue: widget.initialNote,
        maxLength: 180,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => _draftNote = v,
        onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
      ),
      actions: [
        TextButton(
          onPressed: () => _safePop(PrivateNoteDialogCancelled()),
          child: const Text('Annuleren'),
        ),
        if (widget.hasInitialNote)
          TextButton(
            onPressed: () => _safePop(PrivateNoteDialogDelete()),
            child: const Text('Verwijderen'),
          ),
        ElevatedButton(
          onPressed: () {
            final note = _draftNote.trim();
            if (note.isEmpty) {
              if (widget.hasInitialNote) {
                _safePop(PrivateNoteDialogDelete());
              } else {
                _safePop(PrivateNoteDialogCancelled());
              }
            } else {
              _safePop(PrivateNoteDialogSave(note));
            }
          },
          child: const Text('Opslaan'),
        ),
      ],
    );
  }
}

final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _googleSignIn.initialize();
  runApp(const KiDuApp());
}

class KiDuApp extends StatelessWidget {
  const KiDuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KiDu',
      theme: ThemeData(useMaterial3: true),
      scaffoldMessengerKey: appScaffoldMessengerKey,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  static String? _lastUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        final currentUid = user?.uid;
        if (currentUid != _lastUid) {
          debugPrint('AuthGate authState change: uid=$_lastUid -> $currentUid');
          _lastUid = currentUid;
        }
        if (user == null) {
          return const LoginPage();
        }

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          key: ValueKey('profileNameCheck-${user.uid}'),
          future: FirebaseFirestore.instance.doc('users/${user.uid}').get(),
          builder: (context, userDocSnapshot) {
            if (userDocSnapshot.connectionState == ConnectionState.waiting) {
              return const DashboardPage();
            }

            if (userDocSnapshot.hasError) {
              return const ProfileNamePage();
            }

            final data = userDocSnapshot.data?.data();
            final profileName = (data?['profileName'] as String?)?.trim();
            if (profileName == null || profileName.isEmpty) {
              return const ProfileNamePage();
            }

            return const DashboardPage();
          },
        );
      },
    );
  }
}

class ProfileNamePage extends StatefulWidget {
  const ProfileNamePage({super.key});

  @override
  State<ProfileNamePage> createState() => _ProfileNamePageState();
}

class _ProfileNamePageState extends State<ProfileNamePage> {
  final _controller = TextEditingController();
  bool _busy = false;

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnackBar('Niet ingelogd.');
      return;
    }

    final name = _controller.text.trim();
    if (name.length < 2) {
      _showSnackBar('Naam moet minimaal 2 tekens zijn.');
      return;
    }

    setState(() => _busy = true);
    try {
      final stillUser = FirebaseAuth.instance.currentUser;
      if (stillUser == null) {
        _showSnackBar('Niet ingelogd.');
        return;
      }

      final uid = stillUser.uid;
      await FirebaseFirestore.instance.doc('users/$uid').set(
        {'profileName': name},
        SetOptions(merge: true),
      );

      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DashboardPage()),
      );
    } catch (e) {
      debugPrint('Save profileName error: $e');
      _showSnackBar(mapUserFacingError(e, fallback: 'Opslaan mislukt. Probeer opnieuw.'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('KiDu')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                const Text('Niet ingelogd'),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const AuthGate()),
                        (route) => false,
                      );
                    },
                    child: const Text('Naar login'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('KiDu')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Text(
                'Hoe mogen we je noemen?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              Text('Ingelogd als: ${user.email ?? '(geen)'}'),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLength: 20,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _busy ? null : _save(),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Bezig...' : 'Opslaan'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _error;
  bool _busy = false;

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) {
      return;
    }

    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      // a) Trigger Google Sign-In flow (google_sign_in 7.x)
      final googleUser = await _googleSignIn.authenticate();

      // b) Obtain auth details
      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.trim().isEmpty) {
        const message = 'Google-token ontbreekt. Probeer opnieuw.';
        if (mounted) {
          setState(() => _error = message);
          _showSnackBar(message);
        }
        return;
      }

      // d) Create Firebase credential
      final credential = GoogleAuthProvider.credential(
        idToken: idToken,
      );

      // e) Sign in to Firebase
      await FirebaseAuth.instance.signInWithCredential(credential);
      debugPrint(
        'After sign-in currentUser: uid=${FirebaseAuth.instance.currentUser?.uid} '
        'email=${FirebaseAuth.instance.currentUser?.email}',
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('Google sign-in FirebaseAuthException: $e');
      final message = mapUserFacingError(e);
      if (mounted) {
        setState(() => _error = message);
      }
      _showSnackBar(message);
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      if (e is PlatformException) {
        debugPrint(
          'PlatformException code=${e.code} message=${e.message} details=${e.details}',
        );
      }
      final message =
          mapUserFacingError(e, fallback: 'Google-inloggen mislukt. Probeer opnieuw.');
      if (mounted) {
        setState(() => _error = message);
      }
      _showSnackBar(message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/images/kidu_logo.png', width: 180),
                  const SizedBox(height: 24),
                  const Text(
                    'Log in met Google om verder te gaan',
                    style: TextStyle(fontSize: 16, color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _signInWithGoogle,
                      icon: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(_busy ? 'Bezig...' : 'Doorgaan met Google'),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _setupBusy = false;
  bool _inviteBusy = false;
  bool _switchBusy = false;
  bool _expenseBusy = false;
  String? _inviteCode;
  int _notesRefreshTick = 0;
  bool _noteWriteInFlight = false;

  String? _namesCacheKey;
  Future<Map<String, String>>? _namesFuture;

  Future<String?> _loadMyPrivateNote({
    required String householdId,
    required String expenseId,
    required String uid,
  }) async {
    final snap = await FirebaseFirestore.instance
        .doc('households/$householdId/expenses/$expenseId/privateNotes/$uid')
        .get();
    final data = snap.data();
    final raw = (data?['note'] as String?)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  static const double _pagePadding = 16;
  static const double _cardRadius = 18;
  static const double _cardGap = 16;

  Widget _buildBalanceMeter(
    BuildContext context, {
    required int myPaidCents,
    required int otherPaidCents,
    required int totalCents,
    required String myName,
    required String otherName,
  }) {
    final cs = Theme.of(context).colorScheme;
    const barHeight = 8.0;
    const barRadius = 4.0;

    if (totalCents == 0) {
      return Semantics(
        label: 'Bijdragemeter: geen uitgaven',
        child: Container(
          height: barHeight,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha((0.5 * 255).round()),
            borderRadius: BorderRadius.circular(barRadius),
          ),
        ),
      );
    }

    final myPercent = totalCents > 0
        ? ((myPaidCents / totalCents) * 100).round()
        : 0;
    final otherPercent = totalCents > 0
        ? ((otherPaidCents / totalCents) * 100).round()
        : 0;

    return Semantics(
      label: 'Bijdragemeter: $myName $myPercent%, $otherName $otherPercent%',
      child: Row(
        children: [
          if (myPaidCents > 0)
            Expanded(
              flex: myPaidCents,
              child: Container(
                height: barHeight,
                decoration: BoxDecoration(
                  color: cs.primary.withAlpha((0.45 * 255).round()),
                  borderRadius: BorderRadius.horizontal(
                    left: const Radius.circular(barRadius),
                    right: otherPaidCents > 0
                        ? Radius.zero
                        : const Radius.circular(barRadius),
                  ),
                ),
              ),
            ),
          if (otherPaidCents > 0)
            Expanded(
              flex: otherPaidCents,
              child: Container(
                height: barHeight,
                decoration: BoxDecoration(
                  color: cs.secondary.withAlpha((0.45 * 255).round()),
                  borderRadius: BorderRadius.horizontal(
                    left: myPaidCents > 0
                        ? Radius.zero
                        : const Radius.circular(barRadius),
                    right: const Radius.circular(barRadius),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSettlementStatusChip(
    BuildContext context, {
    required int settlementCents,
  }) {
    final cs = Theme.of(context).colorScheme;
    final String label;
    final Color chipColor;
    if (settlementCents > 0) {
      label = 'Jij krijgt terug';
      chipColor = cs.primary.withAlpha((0.18 * 255).round());
    } else if (settlementCents < 0) {
      label = 'Jij betaalt';
      chipColor = cs.secondary.withAlpha((0.18 * 255).round());
    } else {
      label = 'In balans';
      chipColor = cs.surfaceContainerHighest.withAlpha((0.4 * 255).round());
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(chipColor, cs.surface),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: cs.outlineVariant.withAlpha((0.4 * 255).round()),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withAlpha((0.85 * 255).round()),
            ),
      ),
    );
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openEditPrivateNoteDialog({
    required String householdId,
    required String expenseId,
    required String uid,
    required String initialNote,
  }) async {
    if (_noteWriteInFlight) return;
    _noteWriteInFlight = true;

    try {
      final result = await _showPrivateNoteDialog(
        initialNote: initialNote,
        hasInitialNote: initialNote.trim().isNotEmpty,
      );

      if (result is PrivateNoteDialogCancelled) {
        return;
      }

      if (!mounted) return;

      final ref = FirebaseFirestore.instance.doc(
        'households/$householdId/expenses/$expenseId/privateNotes/$uid',
      );

      if (result is PrivateNoteDialogDelete) {
        await ref.delete();
      } else if (result is PrivateNoteDialogSave) {
        await ref.set({
          'note': result.note,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      setState(() => _notesRefreshTick++);
      if (result is PrivateNoteDialogDelete) {
        _showSnackBar('Notitie verwijderd.');
      } else if (result is PrivateNoteDialogSave) {
        _showSnackBar('Notitie opgeslagen.');
      }
    } catch (e) {
      debugPrint('Note save error: $e');
      if (mounted) {
        _showSnackBar(mapUserFacingError(e, fallback: 'Opslaan mislukt. Probeer opnieuw.'));
      }
    } finally {
      _noteWriteInFlight = false;
    }
  }

  /// Dialog only collects input and returns typed result. No Firestore.
  Future<PrivateNoteDialogResult> _showPrivateNoteDialog({
    required String initialNote,
    required bool hasInitialNote,
  }) async {
    final result = await showDialog<PrivateNoteDialogResult>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (dialogContext) => _PrivateNoteDialogContent(
        initialNote: initialNote,
        hasInitialNote: hasInitialNote,
      ),
    );
    return result ?? PrivateNoteDialogCancelled();
  }

  int? _tryParseEurToCents(String input) {
    final raw = input.trim().replaceAll(' ', '');
    if (raw.isEmpty) {
      return null;
    }
    final normalized = raw.replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(normalized)) {
      return null;
    }

    final parts = normalized.split('.');
    final euros = int.tryParse(parts[0]) ?? 0;
    var cents = 0;
    if (parts.length == 2 && parts[1].isNotEmpty) {
      final frac = parts[1];
      if (frac.length == 1) {
        cents = int.parse(frac) * 10;
      } else if (frac.length == 2) {
        cents = int.parse(frac);
      } else {
        return null;
      }
    }
    return euros * 100 + cents;
  }

  String _formatEur(int cents) {
    final value = (cents / 100.0).toStringAsFixed(2);
    return '€$value';
  }

  Future<Map<String, String>> _fetchUserNames({
    required String myUid,
    required String? otherUid,
    required String myFallback,
    required String otherFallback,
  }) async {
    final result = <String, String>{};

    Future<void> loadOne(String uid, String fallback) async {
      try {
        final snap = await FirebaseFirestore.instance.doc('users/$uid').get();
        final data = snap.data();
        final profileName = (data?['profileName'] as String?)?.trim();
        final displayName = (data?['displayName'] as String?)?.trim();
        final email = (data?['email'] as String?)?.trim();

        final effective =
            (profileName != null && profileName.isNotEmpty)
                ? profileName
                : (displayName != null && displayName.isNotEmpty)
                    ? displayName
                    : (email != null && email.isNotEmpty)
                        ? email
                        : fallback;
        result[uid] = effective;
      } catch (e) {
        debugPrint('Fetch user name error (uid=$uid): $e');
        result[uid] = fallback;
      }
    }

    await loadOne(myUid, myFallback);
    if (otherUid != null && otherUid.trim().isNotEmpty) {
      await loadOne(otherUid, otherFallback);
    }
    return result;
  }

  Future<Map<String, String>> _getNamesFuture({
    required String householdId,
    required String myUid,
    required String? otherUid,
    required String myFallback,
    required String otherFallback,
  }) {
    final key = '$householdId|$myUid|${otherUid ?? ''}';
    if (_namesFuture == null || _namesCacheKey != key) {
      _namesCacheKey = key;
      _namesFuture = _fetchUserNames(
        myUid: myUid,
        otherUid: otherUid,
        myFallback: myFallback,
        otherFallback: otherFallback,
      );
    }
    return _namesFuture!;
  }

  void _openMenuSheet({
    required String householdId,
    required String myUid,
    required String? otherName,
    required bool canInvite,
  }) {
    final rootContext = context;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final effectiveOtherName =
                (otherName != null && otherName.trim().isNotEmpty)
                    ? otherName.trim()
                    : 'Co-parent';

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: _pagePadding,
                  right: _pagePadding,
                  top: 8,
                  bottom: _pagePadding + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Instellingen',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Verbonden met: $effectiveOtherName',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withAlpha((0.68 * 255).round()),
                              height: 1.35,
                            ),
                      ),
                      const SizedBox(height: _cardGap),
                      if (canInvite) ...[
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _inviteBusy
                                ? null
                                : () async {
                                    HapticFeedback.selectionClick();
                                    await _generateInvite(householdId);
                                    if (context.mounted) {
                                      setModalState(() {});
                                    }
                                  },
                            child: Text(
                              _inviteBusy
                                  ? 'Bezig...'
                                  : 'Genereer invite code',
                            ),
                          ),
                        ),
                        if (_inviteCode != null &&
                            _inviteCode!.trim().isNotEmpty) ...[
                          const SizedBox(height: _cardGap),
                          KiduCodePill(
                            code: _inviteCode!.trim(),
                            onCopy: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _inviteCode!.trim()),
                              );
                              _showSnackBar('Invite code gekopieerd.');
                            },
                          ),
                        ],
                        const SizedBox(height: _cardGap),
                      ],
                      if (householdId.isNotEmpty) ...[
                        const SizedBox(height: _cardGap),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.of(rootContext).push(
                                MaterialPageRoute(
                                  builder: (_) => const SetupPage(),
                                ),
                              );
                            },
                            icon: const Icon(Icons.link, size: 20),
                            label: const Text('Ik heb een invite-code'),
                          ),
                        ),
                      ],
                      const Divider(height: 24),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.switch_account),
                        title: const Text('Wissel account'),
                        onTap: _switchBusy
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (!mounted) {
                                    return;
                                  }
                                  _switchAccount(rootContext);
                                });
                              },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.logout),
                        title: const Text('Uitloggen'),
                        onTap: () {
                          Navigator.of(context).pop();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) {
                              return;
                            }
                            _signOut(rootContext);
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _createExpense({
    required String householdId,
    required String title,
    required int amountCents,
    String? note,
  }) async {
    if (_expenseBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showSnackBar('Niet ingelogd.');
      return;
    }

    setState(() => _expenseBusy = true);
    try {
      final ref = await FirebaseFirestore.instance
          .collection('households/$householdId/expenses')
          .add({
            'amountCents': amountCents,
            'currency': 'EUR',
            'title': title,
            'createdAt': FieldValue.serverTimestamp(),
            'createdBy': uid,
          });
      final noteTrimmed = note?.trim();
      if (noteTrimmed != null && noteTrimmed.isNotEmpty) {
        try {
          await ref
              .collection('privateNotes')
              .doc(uid)
              .set({
                'note': noteTrimmed,
                'updatedAt': FieldValue.serverTimestamp(),
              });
          _showSnackBar('Uitgave opgeslagen.');
        } catch (noteErr) {
          debugPrint('Private note write error: $noteErr');
          _showSnackBar(
            'Uitgave opgeslagen, ${mapUserFacingError(noteErr, fallback: 'notitie niet opgeslagen.')}',
          );
        }
      } else {
        _showSnackBar('Uitgave opgeslagen.');
      }
    } catch (e) {
      debugPrint('Create expense error: $e');
      rethrow;
    } finally {
      if (mounted) {
        setState(() => _expenseBusy = false);
      }
    }
  }

  Future<void> _openAddExpenseDialog(String householdId) async {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    var saving = false;

    try {
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              return Align(
                alignment: const Alignment(0, -0.15),
                child: AlertDialog(
                  title: const Text('Nieuwe uitgave'),
                  content: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.32,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(
                            controller: titleController,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Titel',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Bedrag (EUR)',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              border: OutlineInputBorder(),
                              hintText: '12,34',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: noteController,
                            maxLength: 180,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Notitie (optioneel)',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: saving ? null : () => Navigator.of(context).pop(),
                      child: const Text('Annuleren'),
                    ),
                    ElevatedButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final title = titleController.text.trim();
                              final amountCents =
                                  _tryParseEurToCents(amountController.text);
                              if (title.isEmpty) {
                                _showSnackBar('Vul een titel in.');
                                return;
                              }
                              if (amountCents == null || amountCents <= 0) {
                                _showSnackBar('Vul een geldig bedrag in.');
                                return;
                              }

                              setLocalState(() => saving = true);
                              try {
                                await _createExpense(
                                  householdId: householdId,
                                  title: title,
                                  amountCents: amountCents,
                                  note: noteController.text.trim().isEmpty
                                      ? null
                                      : noteController.text.trim(),
                                );
                                if (context.mounted) {
                                  Navigator.of(context, rootNavigator: true).maybePop();
                                }
                              } catch (e) {
                                debugPrint('Create expense (dialog) error: $e');
                                _showSnackBar(
                                  mapUserFacingError(e,
                                      fallback: 'Opslaan mislukt. Probeer opnieuw.'),
                                );
                              } finally {
                                if (context.mounted) {
                                  setLocalState(() => saving = false);
                                }
                              }
                            },
                      child: Text(saving ? 'Bezig...' : 'Opslaan'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      // Wait a moment so the dialog route can fully dispose (prevents
      // TextEditingController used-after-dispose during pop animation).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      titleController.dispose();
      amountController.dispose();
      noteController.dispose();
    }
  }

  Future<void> ensureUserDoc() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        return;
      }
      final uid = currentUser.uid;
      final docRef = FirebaseFirestore.instance.doc('users/$uid');
      final snapshot = await docRef.get();

      final data = {
        'displayName': currentUser.displayName,
        'email': currentUser.email,
        'photoUrl': currentUser.photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!snapshot.exists) 'createdAt': FieldValue.serverTimestamp(),
      };

      await docRef.set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('ensureUserDoc error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    ensureUserDoc();
  }

  Future<void> _startSetup() async {
    if (_setupBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showSnackBar('Niet ingelogd.');
      return;
    }

    setState(() => _setupBusy = true);

    try {
      final firestore = FirebaseFirestore.instance;
      final userRef = firestore.doc('users/$uid');

      final result = await firestore.runTransaction<Map<String, dynamic>>((
        transaction,
      ) async {
        final userSnap = await transaction.get(userRef);
        final userData = userSnap.data();
        final existingHouseholdId =
            (userData?['householdId'] as String?)?.trim();

        if (existingHouseholdId != null && existingHouseholdId.isNotEmpty) {
          return {
            'alreadyExists': true,
            'householdId': existingHouseholdId,
          };
        }

        final householdRef = firestore.collection('households').doc();
        transaction.set(householdRef, {
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
          'name': 'KiDu Household',
          'isConnected': false,
        });

        final memberRef = householdRef.collection('members').doc(uid);
        transaction.set(memberRef, {
          'role': 'parent',
          'joinedAt': FieldValue.serverTimestamp(),
        });

        transaction.set(
          userRef,
          {
            'householdId': householdRef.id,
            'setupCompletedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        return {
          'alreadyExists': false,
          'householdId': householdRef.id,
        };
      });

      final alreadyExists = result['alreadyExists'] == true;
      final householdId = result['householdId'] as String?;

      if (alreadyExists) {
        _showSnackBar('Setup bestaat al');
        return;
      }

      _showSnackBar(
        householdId == null ? 'Setup gestart.' : 'Setup gestart: $householdId',
      );
    } catch (e) {
      debugPrint('Start setup error: $e');
      _showSnackBar(mapUserFacingError(e, fallback: 'Setup mislukt. Probeer opnieuw.'));
    } finally {
      if (mounted) {
        setState(() => _setupBusy = false);
      }
    }
  }

  String _randomInviteCode(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _generateInvite(String householdId) async {
    if (_inviteBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showSnackBar('Niet ingelogd.');
      return;
    }

    setState(() => _inviteBusy = true);

    try {
      final firestore = FirebaseFirestore.instance;

      final membersSnap = await firestore
          .collection('households/$householdId/members')
          .limit(2)
          .get();
      if (membersSnap.size >= 2) {
        _showSnackBar('Household is al vol.');
        return;
      }

      String? createdCode;
      Object? lastError;

      for (var attempt = 0; attempt < 6; attempt++) {
        final code = _randomInviteCode(8);
        final inviteRef = firestore.collection('invites').doc(code);

        try {
          await firestore.runTransaction((transaction) async {
            final snap = await transaction.get(inviteRef);
            if (snap.exists) {
              throw StateError('Invite code collision');
            }
            transaction.set(inviteRef, {
              'householdId': householdId,
              'createdBy': uid,
              'createdAt': FieldValue.serverTimestamp(),
              'usedBy': null,
            });
          });

          createdCode = code;
          break;
        } catch (e) {
          lastError = e;
        }
      }

      if (createdCode == null) {
        debugPrint('Generate invite error: $lastError');
        _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
        return;
      }

      if (mounted) {
        setState(() => _inviteCode = createdCode);
      }
      _showSnackBar('Invite code gegenereerd.');
    } catch (e) {
      debugPrint('Generate invite error: $e');
      _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
    } finally {
      if (mounted) {
        setState(() => _inviteBusy = false);
      }
    }
  }

  Future<void> _switchAccount(BuildContext context) async {
    if (_switchBusy) {
      return;
    }

    setState(() => _switchBusy = true);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);

    try {
      debugPrint(
        'Before sign-out currentUser: uid=${FirebaseAuth.instance.currentUser?.uid} '
        'email=${FirebaseAuth.instance.currentUser?.email}',
      );
      await _googleSignIn.signOut(); // clear current Google session
      await FirebaseAuth.instance.signOut();
      debugPrint(
        'After sign-out currentUser: uid=${FirebaseAuth.instance.currentUser?.uid} '
        'email=${FirebaseAuth.instance.currentUser?.email}',
      );
    } catch (e) {
      debugPrint('Switch account error: $e');
    }

    if (!mounted) {
      return;
    }
    setState(() => _switchBusy = false);

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
      (_) => false,
    );

    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(content: Text('Uitgelogd. Kies een ander Google-account.')),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
    }
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Google was mogelijk al uitgelogd — negeren
    }

    if (!context.mounted) {
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Test checklist:
    // - 2 users in household -> invite knop verdwijnt (menu)
    // - switch account werkt (terug naar login)
    // - add expense -> verschijnt bovenaan
    // - balans klopt bij even/oneven total cents (geen €0.01 drift)
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Avoid endless spinner if auth state flips during navigation/sign-out.
      return const AuthGate();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.doc('users/${user.uid}').snapshots(),
      builder: (context, snapshot) {
        final cs = Theme.of(context).colorScheme;
        final data = snapshot.data?.data();
        final myProfileName = (data?['profileName'] as String?)?.trim();
        final householdId = (data?['householdId'] as String?)?.trim();
        final hasHousehold =
            householdId != null && householdId.trim().isNotEmpty;

        final myFallbackName =
            (myProfileName != null && myProfileName.isNotEmpty)
                ? myProfileName
                : (user.displayName != null && user.displayName!.trim().isNotEmpty)
                    ? user.displayName!.trim()
                    : (user.email != null && user.email!.trim().isNotEmpty)
                        ? user.email!.trim()
                        : 'Jij';

        final background = Color.alphaBlend(
          cs.primary.withAlpha((0.05 * 255).round()),
          cs.surface,
        );

        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: background,
            appBar: AppBar(
              title: const Text('KiDu'),
              actions: [
                IconButton(
                  onPressed: () => _openMenuSheet(
                    householdId: '',
                    myUid: user.uid,
                    otherName: null,
                    canInvite: false,
                  ),
                  icon: const Icon(Icons.more_horiz),
                  tooltip: 'Menu',
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(_pagePadding),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Accountgegevens konden niet worden geladen.'),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 48,
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed:
                                _switchBusy ? null : () => _switchAccount(context),
                            child: const Text('Wissel account'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        if (!hasHousehold) {
          return Scaffold(
            backgroundColor: background,
            appBar: AppBar(
              title: const Text('KiDu'),
              actions: [
                IconButton(
                  onPressed: () => _openMenuSheet(
                    householdId: '',
                    myUid: user.uid,
                    otherName: null,
                    canInvite: false,
                  ),
                  icon: const Icon(Icons.more_horiz),
                  tooltip: 'Menu',
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(_pagePadding),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Nog niet gekoppeld',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Koppel door te starten of met een invite-code.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: cs.onSurface.withAlpha(
                                    (0.66 * 255).round(),
                                  ),
                                  height: 1.35,
                                ),
                          ),
                          const SizedBox(height: _cardGap),
                          KiduCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Acties',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: _cardGap),
                                SizedBox(
                                  height: 48,
                                  child: ElevatedButton(
                                    onPressed: _setupBusy
                                        ? null
                                        : () {
                                            HapticFeedback.selectionClick();
                                            _startSetup();
                                          },
                                    child:
                                        Text(_setupBusy ? 'Bezig...' : 'Start setup'),
                                  ),
                                ),
                                const SizedBox(height: _cardGap),
                                SizedBox(
                                  height: 48,
                                  child: OutlinedButton(
                                    onPressed: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => const SetupPage(),
                                        ),
                                      );
                                    },
                                    child: const Text('Join household'),
                                  ),
                                ),
                                const SizedBox(height: _cardGap),
                                SizedBox(
                                  height: 48,
                                  child: OutlinedButton(
                                    onPressed: _switchBusy
                                        ? null
                                        : () => _switchAccount(context),
                                    child: Text(
                                      _switchBusy ? 'Bezig...' : 'Wissel account',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final householdIdStr = householdId.trim();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('households/$householdIdStr/members')
              .limit(2)
              .snapshots(),
          builder: (context, membersSnapshot) {
            final memberDocs = membersSnapshot.data?.docs ?? const [];
            final memberCount = memberDocs.length;

            String? otherUid;
            for (final d in memberDocs) {
              if (d.id != user.uid) {
                otherUid = d.id;
                break;
              }
            }

            final canInvite = memberCount == 1;
            final canAddExpenses =
                otherUid != null && otherUid.trim().isNotEmpty;
            final namesFuture = _getNamesFuture(
              householdId: householdIdStr,
              myUid: user.uid,
              otherUid: otherUid,
              myFallback: myFallbackName,
              otherFallback: 'Co-parent',
            );

            return FutureBuilder<Map<String, String>>(
              future: namesFuture,
              builder: (context, namesSnapshot) {
                final names = namesSnapshot.data ?? const <String, String>{};
                final myName = names[user.uid] ?? myFallbackName;
                final otherName = otherUid == null
                    ? 'Co-parent'
                    : (names[otherUid] ?? 'Co-parent');

                return Scaffold(
                  backgroundColor: background,
                  appBar: AppBar(
                    title: const Text('KiDu'),
                    actions: [
                      IconButton(
                        onPressed: () => _openMenuSheet(
                          householdId: householdIdStr,
                          myUid: user.uid,
                          otherName: otherName,
                          canInvite: canInvite,
                        ),
                        icon: const Icon(Icons.more_horiz),
                        tooltip: 'Menu',
                      ),
                    ],
                  ),
                  floatingActionButton: FloatingActionButton(
                    onPressed: _expenseBusy || !canAddExpenses
                        ? null
                        : () => _openAddExpenseDialog(householdIdStr),
                    child: const Icon(Icons.add),
                  ),
                  body: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(_pagePadding),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: min(constraints.maxWidth, 520.0),
                              height: constraints.maxHeight,
                              child: StreamBuilder<
                                  QuerySnapshot<Map<String, dynamic>>>(
                                stream: FirebaseFirestore.instance
                                    .collection('households/$householdIdStr/expenses')
                                    .orderBy('createdAt', descending: true)
                                    .limit(20)
                                    .snapshots(),
                                builder: (context, expensesSnapshot) {
                                  if (expensesSnapshot.hasError) {
                                    return const Text('Kon uitgaven niet laden.');
                                  }

                                  final docs =
                                      expensesSnapshot.data?.docs ?? const [];

                                  var totalCents = 0;
                                  var myPaidCents = 0;
                                  for (final d in docs) {
                                    final e = d.data();
                                    final amountCents =
                                        (e['amountCents'] as num?)?.toInt() ?? 0;
                                    totalCents += amountCents;
                                    final createdBy =
                                        (e['createdBy'] as String?)?.trim();
                                    if (createdBy == user.uid) {
                                      myPaidCents += amountCents;
                                    }
                                  }
                                  final otherPaidCents = totalCents - myPaidCents;
                                  final halfFloor = totalCents ~/ 2;
                                  final remainder = totalCents % 2;
                                  final expectedMy = halfFloor +
                                      ((remainder == 1 &&
                                              myPaidCents < otherPaidCents)
                                          ? 1
                                          : 0);
                                  final settlementCents = myPaidCents - expectedMy;

                                  final absSettlement = settlementCents.abs();
                                  final settlementText = settlementCents > 0
                                      ? '$otherName betaalt jou ${_formatEur(absSettlement)}'
                                      : settlementCents < 0
                                          ? 'Jij betaalt $otherName ${_formatEur(absSettlement)}'
                                          : 'Jullie zijn in balans';

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      KiduCard(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              'Balans',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            const SizedBox(height: _cardGap),
                                            _balanceRow(
                                              label: 'Totaal',
                                              value: _formatEur(totalCents),
                                            ),
                                            const SizedBox(height: 8),
                                            _balanceRow(
                                              label: myName,
                                              value: _formatEur(myPaidCents),
                                            ),
                                            const SizedBox(height: 8),
                                            _balanceRow(
                                              label: otherName,
                                              value: _formatEur(otherPaidCents),
                                            ),
                                            const SizedBox(height: 12),
                                            _buildBalanceMeter(
                                              context,
                                              myPaidCents: myPaidCents,
                                              otherPaidCents: otherPaidCents,
                                              totalCents: totalCents,
                                              myName: myName,
                                              otherName: otherName,
                                            ),
                                            const SizedBox(height: _cardGap),
                                            Builder(
                                              builder: (context) {
                                                final rawShare = totalCents <= 0
                                                    ? 0.5
                                                    : myPaidCents / totalCents;
                                                final myShare = rawShare
                                                    .clamp(0.0, 1.0)
                                                    .toDouble();
                                                final myPct =
                                                    (myShare * 100).round();
                                                final otherPct = 100 - myPct;

                                                return Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        999,
                                                      ),
                                                      child:
                                                          LinearProgressIndicator(
                                                        minHeight: 10,
                                                        value: myShare,
                                                        backgroundColor: cs
                                                            .outlineVariant
                                                            .withAlpha(
                                                          (0.25 * 255).round(),
                                                        ),
                                                        valueColor:
                                                            AlwaysStoppedAnimation<
                                                                Color>(
                                                          cs.primary,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(
                                                          '$myName $myPct%',
                                                          style: Theme.of(
                                                            context,
                                                          )
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: cs
                                                                    .onSurface
                                                                    .withAlpha(
                                                                  (0.72 * 255)
                                                                      .round(),
                                                                ),
                                                              ),
                                                        ),
                                                        Text(
                                                          '$otherName $otherPct%',
                                                          style: Theme.of(
                                                            context,
                                                          )
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: cs
                                                                    .onSurface
                                                                    .withAlpha(
                                                                  (0.72 * 255)
                                                                      .round(),
                                                                ),
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                            const SizedBox(height: _cardGap),
                                            Divider(
                                              height: 1,
                                              color: cs.outlineVariant.withAlpha(
                                                (0.45 * 255).round(),
                                              ),
                                            ),
                                            const SizedBox(height: _cardGap),
                                            Text(
                                              settlementText,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w500,
                                                    color: cs.onSurface.withAlpha(
                                                      (0.84 * 255).round(),
                                                    ),
                                                    height: 1.35,
                                                  ),
                                            ),
                                            const SizedBox(height: 10),
                                            _buildSettlementStatusChip(
                                              context,
                                              settlementCents: settlementCents,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: _cardGap),
                                      Expanded(
                                        child: KiduCard(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Text(
                                                'Uitgaven',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              if (!canAddExpenses) ...[
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Nog niet gekoppeld. Uitgaven toevoegen kan zodra je co-parent is verbonden.',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: cs.onSurface
                                                            .withAlpha(
                                                              (0.62 * 255)
                                                                  .round(),
                                                            ),
                                                        height: 1.35,
                                                      ),
                                                ),
                                              ],
                                              const SizedBox(height: 10),
                                              Expanded(
                                                child: !expensesSnapshot.hasData
                                                    ? const Center(
                                                        child:
                                                            CircularProgressIndicator(),
                                                      )
                                                    : docs.isEmpty
                                                        ? Align(
                                                            alignment:
                                                                Alignment.topLeft,
                                                            child: Text(
                                                              'Nog geen uitgaven. Voeg er een toe met +.',
                                                              style: Theme.of(context)
                                                                  .textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                    color: cs
                                                                        .onSurface
                                                                        .withAlpha(
                                                                      (0.62 * 255)
                                                                          .round(),
                                                                    ),
                                                                    height: 1.35,
                                                                  ),
                                                            ),
                                                          )
                                                        : ListView.separated(
                                                            itemCount: docs.length,
                                                            separatorBuilder:
                                                                (context, index) =>
                                                                    Divider(
                                                              height: 16,
                                                              color: cs
                                                                  .outlineVariant
                                                                  .withAlpha(
                                                                (0.40 * 255)
                                                                    .round(),
                                                              ),
                                                            ),
                                                            itemBuilder:
                                                                (context, index) {
                                                              final d =
                                                                  docs[index];
                                                              final e = d.data();
                                                              final title =
                                                                  (e['title']
                                                                              as String?)
                                                                          ?.trim() ??
                                                                      '(zonder)';
                                                              final amountCents =
                                                                  (e['amountCents']
                                                                              as num?)
                                                                          ?.toInt() ??
                                                                      0;
                                                              final createdBy =
                                                                  (e['createdBy']
                                                                          as String?)
                                                                      ?.trim();

                                                              final who = createdBy ==
                                                                      user.uid
                                                                  ? myName
                                                                  : (otherUid !=
                                                                              null &&
                                                                          createdBy ==
                                                                              otherUid)
                                                                      ? otherName
                                                                      : 'Co-parent';
                                                              final createdAtRaw =
                                                                  e['createdAt'];
                                                              DateTime?
                                                              createdAtDateTime;
                                                              if (createdAtRaw
                                                                  is Timestamp) {
                                                                createdAtDateTime =
                                                                    createdAtRaw
                                                                        .toDate()
                                                                        .toLocal();
                                                              } else if (createdAtRaw
                                                                  is DateTime) {
                                                                createdAtDateTime =
                                                                    createdAtRaw
                                                                        .toLocal();
                                                              }
                                                              final subtitleText =
                                                                  createdAtDateTime ==
                                                                      null
                                                                  ? who
                                                                  : (() {
                                                                      final dt =
                                                                          createdAtDateTime;
                                                                      if (dt ==
                                                                          null) {
                                                                        return who;
                                                                      }
                                                                      const nlMonths = <
                                                                        String
                                                                      >[
                                                                        'jan',
                                                                        'feb',
                                                                        'mrt',
                                                                        'apr',
                                                                        'mei',
                                                                        'jun',
                                                                        'jul',
                                                                        'aug',
                                                                        'sep',
                                                                        'okt',
                                                                        'nov',
                                                                        'dec',
                                                                      ];
                                                                      final shortDateTime =
                                                                          '${dt.day} ${nlMonths[dt.month - 1]} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                                                                      return '$who • $shortDateTime';
                                                                    })();

                                                              if (createdBy != user.uid) {
                                                                return ListTile(
                                                                  contentPadding: EdgeInsets.zero,
                                                                  dense: true,
                                                                  visualDensity: VisualDensity.compact,
                                                                  title: Text(
                                                                    title,
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                  ),
                                                                  subtitle: Text(
                                                                    subtitleText,
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                  ),
                                                                  trailing: Text(
                                                                    _formatEur(amountCents),
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .bodyMedium
                                                                        ?.copyWith(
                                                                          fontWeight: FontWeight.w700,
                                                                        ),
                                                                  ),
                                                                );
                                                              }

                                                              return FutureBuilder<String?>(
                                                                key: ValueKey('note_${d.id}_$_notesRefreshTick'),
                                                                future: _loadMyPrivateNote(
                                                                  householdId: householdIdStr,
                                                                  expenseId: d.id,
                                                                  uid: user.uid,
                                                                ),
                                                                builder: (context, noteSnap) {
                                                                  final note = noteSnap.data;
                                                                  final hasNote = note != null && note.isNotEmpty;

                                                                  return ListTile(
                                                                    contentPadding: EdgeInsets.zero,
                                                                    dense: true,
                                                                    visualDensity: VisualDensity.compact,
                                                                    title: Text(
                                                                      title,
                                                                      maxLines: 1,
                                                                      overflow: TextOverflow.ellipsis,
                                                                    ),
                                                                    subtitle: (noteSnap.hasError || !noteSnap.hasData)
                                                                        ? Text(
                                                                            subtitleText,
                                                                            maxLines: 1,
                                                                            overflow: TextOverflow.ellipsis,
                                                                          )
                                                                        : (hasNote
                                                                            ? Column(
                                                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                                                mainAxisSize: MainAxisSize.min,
                                                                                children: [
                                                                                  Text(
                                                                                    subtitleText,
                                                                                    maxLines: 1,
                                                                                    overflow: TextOverflow.ellipsis,
                                                                                  ),
                                                                                  Text(
                                                                                    note,
                                                                                    maxLines: 1,
                                                                                    overflow: TextOverflow.ellipsis,
                                                                                  ),
                                                                                ],
                                                                              )
                                                                            : Text(
                                                                                subtitleText,
                                                                                maxLines: 1,
                                                                                overflow: TextOverflow.ellipsis,
                                                                              )),
                                                                    trailing: Row(
                                                                      mainAxisSize: MainAxisSize.min,
                                                                      mainAxisAlignment: MainAxisAlignment.end,
                                                                      children: [
                                                                        IconButton(
                                                                          icon: Icon(
                                                                            hasNote ? Icons.edit_note : Icons.note_add_outlined,
                                                                            size: 20,
                                                                            color: cs.onSurface.withAlpha((0.6 * 255).round()),
                                                                          ),
                                                                          style: IconButton.styleFrom(
                                                                            padding: EdgeInsets.zero,
                                                                            minimumSize: const Size(36, 36),
                                                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                                          ),
                                                                          onPressed: () {
                                                                            _openEditPrivateNoteDialog(
                                                                              householdId: householdIdStr,
                                                                              expenseId: d.id,
                                                                              uid: user.uid,
                                                                              initialNote: note ?? '',
                                                                            );
                                                                          },
                                                                        ),
                                                                        Text(
                                                                          _formatEur(amountCents),
                                                                          style: Theme.of(context)
                                                                              .textTheme
                                                                              .bodyMedium
                                                                              ?.copyWith(
                                                                                fontWeight: FontWeight.w700,
                                                                              ),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  );
                                                                },
                                                              );
                                                            },
                                                          ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

Widget _balanceRow({required String label, required String value}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 12),
      Text(value),
    ],
  );
}

class KiduCard extends StatelessWidget {
  const KiduCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.backgroundColor,
    this.borderColor,
    this.elevation = 0.4,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? backgroundColor;
  final Color? borderColor;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final surface = backgroundColor ?? cs.surface;
    final effectiveBorderColor =
        borderColor ?? cs.outlineVariant.withAlpha((0.55 * 255).round());

    return Material(
      color: surface,
      elevation: elevation,
      borderRadius: BorderRadius.circular(_DashboardPageState._cardRadius),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_DashboardPageState._cardRadius),
          border: Border.all(color: effectiveBorderColor),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

class KiduCodePill extends StatelessWidget {
  const KiduCodePill({super.key, required this.code, required this.onCopy});

  final String code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          cs.primary.withAlpha((0.06 * 255).round()),
          cs.surface,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: cs.outlineVariant.withAlpha((0.45 * 255).round()),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Kopieer'),
            ),
          ),
        ],
      ),
    );
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _inviteController = TextEditingController();
  bool _joinBusy = false;
  bool? _joinOk;

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _joinHousehold() async {
    if (_joinBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showSnackBar('Niet ingelogd.');
      setState(() => _joinOk = false);
      return;
    }

    final code = _inviteController.text.trim().toUpperCase();
    if (code.isEmpty) {
      _showSnackBar('Vul een invite code in.');
      setState(() => _joinOk = false);
      return;
    }

    setState(() {
      _joinBusy = true;
      _joinOk = null;
    });

    try {
      final firestore = FirebaseFirestore.instance;
      final inviteRef = firestore.doc('invites/$code');
      final userRef = firestore.doc('users/$uid');

      final inviteSnap = await inviteRef.get();
      if (!inviteSnap.exists) {
        throw StateError('Invite code ongeldig.');
      }

      final inviteData = inviteSnap.data();
      final usedBy = inviteData?['usedBy'];
      if (usedBy != null) {
        throw StateError('Code al gebruikt.');
      }

      final targetHouseholdId =
          (inviteData?['householdId'] as String?)?.trim();
      if (targetHouseholdId == null || targetHouseholdId.isEmpty) {
        throw StateError('Invite is ongeldig.');
      }

      final userSnap = await userRef.get();
      final userData = userSnap.data();
      final currentHouseholdId =
          (userData?['householdId'] as String?)?.trim();

      if (targetHouseholdId == currentHouseholdId) {
        throw StateError('Je zit al in dit household.');
      }

      if (currentHouseholdId != null && currentHouseholdId.isNotEmpty) {
        final membersSnap = await firestore
            .collection('households/$currentHouseholdId/members')
            .limit(2)
            .get();
        final expensesSnap = await firestore
            .collection('households/$currentHouseholdId/expenses')
            .limit(1)
            .get();
        if (membersSnap.docs.length != 1 ||
            membersSnap.docs.first.id != uid) {
          throw StateError(
              'Wisselen kan alleen als je huidige household leeg is.');
        }
        if (expensesSnap.docs.isNotEmpty) {
          throw StateError(
              'Wisselen kan alleen als je huidige household leeg is.');
        }
      }

      await firestore.runTransaction((transaction) async {
        final inviteRecheck = await transaction.get(inviteRef);
        if (!inviteRecheck.exists) {
          throw StateError('Invite code ongeldig.');
        }
        if ((inviteRecheck.data()?['usedBy']) != null) {
          throw StateError('Code al gebruikt.');
        }
        final hId =
            (inviteRecheck.data()?['householdId'] as String?)?.trim();
        if (hId == null || hId.isEmpty) {
          throw StateError('Invite is ongeldig.');
        }

        final targetMemberRef =
            firestore.doc('households/$hId/members/$uid');
        transaction.set(targetMemberRef, {
          'role': 'parent',
          'joinedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        transaction.set(
          inviteRef,
          {
            'usedBy': uid,
            'usedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        if (currentHouseholdId != null &&
            currentHouseholdId.isNotEmpty &&
            currentHouseholdId != targetHouseholdId) {
          final oldMemberRef = firestore
              .doc('households/$currentHouseholdId/members/$uid');
          transaction.delete(oldMemberRef);
        }
      });

      await firestore.doc('users/$uid').set({
        'householdId': targetHouseholdId,
        'displayName': FirebaseAuth.instance.currentUser!.displayName,
        'email': FirebaseAuth.instance.currentUser!.email,
        'photoUrl': FirebaseAuth.instance.currentUser!.photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // TODO(re-enable after rules alignment): household isConnected update
      // requires allow update on households; temporarily disabled.
      // await firestore.doc('households/$targetHouseholdId').set(
      //   {'isConnected': true},
      //   SetOptions(merge: true),
      // );

      if (mounted) {
        setState(() => _joinOk = true);
        _showSnackBar('Join gelukt.');
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('Join household error: $e');
      final message =
          mapUserFacingError(e, fallback: 'Join mislukt. Probeer opnieuw.');
      if (mounted) {
        setState(() => _joinOk = false);
      }
      _showSnackBar(message);
    } finally {
      if (mounted) {
        setState(() => _joinBusy = false);
      }
    }
  }

  @override
  void dispose() {
    _inviteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('KiDu — Setup')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: uid == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Niet ingelogd.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Terug'),
                  ),
                ],
              )
            : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .doc('users/$uid')
                    .snapshots(),
                builder: (context, snapshot) {
                  final data = snapshot.data?.data();
                  final householdId = (data?['householdId'] as String?)?.trim();
                  final hasHousehold =
                      householdId != null && householdId.isNotEmpty;

                  if (snapshot.hasError) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Kon status niet laden.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Terug'),
                        ),
                      ],
                    );
                  }

                  if (!snapshot.hasData) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Terug'),
                        ),
                      ],
                    );
                  }

                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Voer een invite-code in om te koppelen aan het household van je co-parent.',
                        textAlign: TextAlign.center,
                      ),
                      if (hasHousehold) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Heb je al een household? Dan kun je hiermee veilig wisselen zolang je huidige household leeg is.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withAlpha((0.7 * 255).round()),
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      TextField(
                        controller: _inviteController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Invite code',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _joinBusy ? null : _joinHousehold,
                        child: Text(
                          _joinBusy
                              ? 'Bezig...'
                              : (hasHousehold ? 'Wissel household' : 'Join household'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _joinOk == null
                            ? 'Join: ...'
                            : (_joinOk == true
                                ? 'Join: OK'
                                : 'Join: ERROR'),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Terug'),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
