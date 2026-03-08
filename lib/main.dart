import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sign_in_button/sign_in_button.dart';

import 'firebase_options.dart';

// ------------------------------------------------------------
// Color/alpha helpers (single-file)
// ------------------------------------------------------------
// Common semantic opacities used across the UI.
const double a06 = 0.06;
const double a40 = 0.40;
const double a45 = 0.45;
const double a50 = 0.50;
const double a55 = 0.55;
const double a60 = 0.60;
const double a62 = 0.62;
const double a68 = 0.68;
const double a84 = 0.84;
const double a85 = 0.85;

/// Calm green for success overlays (e.g. join/connect confirmation).
const Color _kSuccessGreen = Color(0xFF2E7D32);

/// Fixed height reserved for the child-picker area in the Add Expense dialog.
/// Both the "all selected" summary pill and the expanded chip grid live inside
/// a SizedBox of this height so the dialog never resizes on toggle.
const double _kChildPickerHeight = 140;

/// Lightweight value-object used by the "Voor wie?" feature.
class _ChildItem {
  const _ChildItem({required this.id, required this.name});
  final String id;
  final String name;
}

Color onSurface(BuildContext context, double alpha) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: alpha);

Color outlineV(BuildContext context, double alpha) =>
    Theme.of(context).colorScheme.outlineVariant.withValues(alpha: alpha);

ThemeData buildKiduTheme() {
  // Keep it warm + premium, no purple defaults.
  const appBg = Color(0xFFF7F6F4);
  const seed = Color(0xFF2F3E46); // warm/dark slate

  final cs = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  ).copyWith(surface: Colors.white, surfaceTint: Colors.transparent);

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: appBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: appBg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF2F3E46),
    ),
  );
}

/// Maps exceptions to user-friendly Dutch messages. Does not throw.
String mapUserFacingError(
  Object e, {
  String fallback = 'Er ging iets mis. Probeer opnieuw.',
}) {
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
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxH = constraints.maxHeight * 0.85;
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Notitie bewerken',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: SingleChildScrollView(
                        child: TextFormField(
                          initialValue: widget.initialNote,
                          maxLength: 180,
                          minLines: 3,
                          maxLines: 8,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                          onChanged: (v) => _draftNote = v,
                          onFieldSubmitted: (_) =>
                              FocusScope.of(context).unfocus(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: () =>
                              _safePop(PrivateNoteDialogCancelled()),
                          child: const Text('Annuleren'),
                        ),
                        if (widget.hasInitialNote)
                          TextButton(
                            onPressed: () =>
                                _safePop(PrivateNoteDialogDelete()),
                            child: const Text('Verwijderen'),
                          ),
                        FilledButton(
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
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
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
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const KiDuApp());
}

class KiDuApp extends StatelessWidget {
  const KiDuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KiDu',
      theme: buildKiduTheme(),
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
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
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

const String _privacyPolicyFull = '''
KiDu Privacybeleid / Privacy Policy
Laatst bijgewerkt: 2026-02-18

NL — Privacybeleid

1. Wie zijn wij?
KiDu is een app om gedeelde kind-uitgaven tussen co-parents bij te houden.
Ontwikkelaar / contact (privacy): meershoek@gmail.com

2. Welke gegevens verwerken we?
Account (inloggen via Google)
- Google-account gegevens die nodig zijn om in te loggen (bijv. e-mail, naam en profielfoto indien beschikbaar).

App-gegevens die jij invoert
- Huishouden (koppeling tussen co-parents).
- Uitgaven (bedrag, omschrijving, datum, wie heeft betaald).
- Invite codes (voor koppelen).
- Privé notities (alleen zichtbaar voor de gebruiker die ze maakt).

Technische gegevens
- We gebruiken Google Firebase (Auth/Firestore) om de app te laten werken. Deze diensten kunnen technische informatie verwerken die nodig is voor werking en beveiliging van de dienst.

3. Waarvoor gebruiken we deze gegevens?
- Inloggen en accountbeheer.
- Koppelen van co-parents binnen één huishouden.
- Opslaan en tonen van uitgaven, balans en privé notities.
- Beveiliging (toegangscontrole op basis van household-membership).

4. Delen we gegevens met derden?
We verkopen geen gegevens.
We gebruiken Google Firebase als verwerker/dienstverlener om inloggen en opslag mogelijk te maken (Firebase Authentication en Cloud Firestore).

5. Beveiliging
- Communicatie verloopt versleuteld (TLS).
- Toegang tot huishouden-data wordt beperkt via Firestore security rules (alleen members van het huishouden).

6. Bewaartermijn
We bewaren gegevens zolang je het account gebruikt.
Wil je gegevens verwijderen? Mail naar: meershoek@gmail.com
We verwijderen je data zo snel mogelijk en uiterlijk binnen 30 dagen, tenzij we wettelijk langer moeten bewaren.

7. Jouw rechten
Je kunt verzoeken om inzage, correctie of verwijdering via: meershoek@gmail.com

8. Kinderen
KiDu is bedoeld voor (co-)ouders/volwassenen en is niet ontworpen voor gebruik door kinderen.

---

EN — Privacy Policy

1. Who we are
KiDu helps co-parents track shared child-related expenses.
Developer / privacy contact: meershoek@gmail.com

2. Data we process
Account (Google sign-in)
- Google account data needed to sign in (e.g., email, name, profile photo if available).

User-provided app data
- Household connection between co-parents.
- Expenses (amount, description, date, who paid).
- Invite codes (for linking).
- Private notes (only visible to the user who created them).

Technical data
- We use Google Firebase (Auth/Firestore). These services may process technical information required for service operation and security.

3. Why we use data
- Authentication and account management.
- Linking co-parents inside one household.
- Storing and displaying expenses, balance, and private notes.
- Security (access control based on household membership).

4. Sharing
We do not sell data.
We use Google Firebase as a service provider (Firebase Authentication and Cloud Firestore).

5. Security
- Encrypted transport (TLS).
- Access restricted via Firestore security rules (household membership).

6. Retention & deletion
We keep data while your account is active.
To request deletion: meershoek@gmail.com
We aim to delete within 30 days unless legally required to retain longer.

7. Your rights
You can request access, correction, or deletion via: meershoek@gmail.com

8. Children
KiDu is intended for adults (co-parents) and is not designed for children.
''';

class ProfileNamePage extends StatefulWidget {
  const ProfileNamePage({
    super.key,
    this.fromSettings = false,
    this.initialName,
  });

  final bool fromSettings;
  final String? initialName;

  @override
  State<ProfileNamePage> createState() => _ProfileNamePageState();
}

class _ProfileNamePageState extends State<ProfileNamePage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _nameInlineHint;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialName;
    if (initial != null && initial.trim().isNotEmpty) {
      _controller.text = initial.trim();
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    final name = _controller.text.trim();
    if (name.length < 2) {
      setState(() => _nameInlineHint = 'Naam moet minimaal 2 tekens zijn.');
      return;
    }

    setState(() => _busy = true);
    try {
      final stillUser = FirebaseAuth.instance.currentUser;
      if (stillUser == null) {
        return;
      }

      final uid = stillUser.uid;
      await FirebaseFirestore.instance.doc('users/$uid').set({
        'profileName': name,
      }, SetOptions(merge: true));

      if (!mounted) {
        return;
      }
      if (widget.fromSettings) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DashboardPage()),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Save profileName error: $e');
      _showSnackBar(
        mapUserFacingError(e, fallback: 'Opslaan mislukt. Probeer opnieuw.'),
      );
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
        appBar: AppBar(
          centerTitle: true,
          title: Text(
            'KiDu',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text(
            'KiDu',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Text(
                  'Welke naam wil je gebruiken?',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Deze naam is zichtbaar in jullie gedeelde KiDu-overzicht.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: onSurface(context, a62),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  maxLength: 20,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _save(),
                  onChanged: (_) {
                    if (_nameInlineHint != null) {
                      setState(() => _nameInlineHint = null);
                    }
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_nameInlineHint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _nameInlineHint!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: onSurface(context, a62),
                      height: 1.35,
                    ),
                  ),
                ],
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
      ),
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const double _pagePadding = 16;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Privacyverklaring',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(_pagePadding),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Text(
                _privacyPolicyFull,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: onSurface(context, a68),
                  height: 1.35,
                ),
              ),
            ),
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
      final credential = GoogleAuthProvider.credential(idToken: idToken);

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
      final message = mapUserFacingError(
        e,
        fallback: 'Google-inloggen mislukt. Probeer opnieuw.',
      );
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
              padding: const EdgeInsets.only(top: 10, bottom: 38),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/images/kidu_logo.png', width: 180),
                      const SizedBox(height: 32),
                      Text(
                        'Rust in gedeelde kosten',
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                              color: onSurface(context, a85),
                            ) ??
                            TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                              color: onSurface(context, a85),
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 40),
                      if (_error != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.error.withValues(alpha: 0.35),
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      IgnorePointer(
                        ignoring: _busy,
                        child: Opacity(
                          opacity: _busy ? 0.6 : 1.0,
                          child: SizedBox(
                            height: 64,
                            width: double.infinity,
                            child: Transform.scale(
                              scale: 1.08,
                              alignment: Alignment.center,
                              child: SignInButton(
                                Buttons.google,
                                onPressed: _signInWithGoogle,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: onSurface(context, a60),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Veilig inloggen via Google',
                              style: TextStyle(
                                fontSize: 13,
                                color: onSurface(context, a60),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
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

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _setupBusy = false;
  bool _inviteBusy = false;
  bool _inviteSheetOpening = false;
  bool _switchBusy = false;
  final ValueNotifier<bool> _addExpenseCheckBusyVN = ValueNotifier(false);
  final ValueNotifier<bool> _freezeExpensesVN = ValueNotifier(false);
  final ValueNotifier<bool> _addExpenseDialogOpenVN = ValueNotifier(false);
  QuerySnapshot<Map<String, dynamic>>? _lastExpensesSnap;
  String? _inviteCode;
  bool _showWaiting = false;
  int _notesRefreshTick = 0;
  bool _noteWriteInFlight = false;
  final Map<String, Future<String?>> _noteFutureCache = {};

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

  Future<String?> _getNoteFuture(String householdId, String expenseId) {
    return _noteFutureCache.putIfAbsent(
      expenseId,
      () => _loadMyPrivateNote(
        householdId: householdId,
        expenseId: expenseId,
        uid: FirebaseAuth.instance.currentUser!.uid,
      ),
    );
  }

  static const double _pagePadding = 16;
  static const double _cardRadius = 18;
  static const double _cardGap = 16;

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

      if (!await _canWriteExpenseNow()) {
        if (mounted) {
          _showSnackBar(
            'Je bent offline. Notitie is niet gewijzigd. Verbind met internet en probeer opnieuw.',
          );
        }
        return;
      }

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
      setState(() {
        _notesRefreshTick++;
        _noteFutureCache.clear();
      });
      if (result is PrivateNoteDialogDelete) {
        _showSnackBar('Notitie verwijderd.');
      } else if (result is PrivateNoteDialogSave) {
        _showSnackBar('Notitie opgeslagen.');
      }
    } catch (e) {
      debugPrint('Note save error: $e');
      if (mounted) {
        _showSnackBar(
          mapUserFacingError(e, fallback: 'Opslaan mislukt. Probeer opnieuw.'),
        );
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
      useSafeArea: true,
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

  String _formatRelativeNl(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'zojuist';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min geleden';
    if (diff.inHours < 24) return '${diff.inHours} uur geleden';
    if (diff.inDays == 1) return 'gisteren';
    if (diff.inDays < 7) return '${diff.inDays} dagen geleden';
    return '${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}';
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

        final effective = (profileName != null && profileName.isNotEmpty)
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
    String? myName,
  }) {
    final rootContext = context;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final trimmedOther = (otherName ?? '').trim();
            final isPaired = trimmedOther.isNotEmpty;
            final hasHousehold = householdId.trim().isNotEmpty;
            final effectiveOtherName = isPaired ? trimmedOther : 'Co-parent';

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: _pagePadding,
                  right: _pagePadding,
                  top: 8,
                  bottom:
                      _pagePadding + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isPaired ? 'Instellingen' : 'Koppel met co-parent',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (isPaired)
                        Text(
                          'Verbonden met $effectiveOtherName',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: onSurface(context, a68),
                                height: 1.35,
                              ),
                        )
                      else
                        Text(
                          'Koppel met je co-parent om samen kosten te delen.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: onSurface(context, a68),
                                height: 1.35,
                              ),
                        ),
                      const SizedBox(height: _cardGap),
                      if (!isPaired && hasHousehold && canInvite) ...[
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
                              _inviteBusy ? 'Bezig...' : 'Genereer invite code',
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
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () => _shareInviteCode(_inviteCode!),
                            icon: const Icon(Icons.share),
                            label: const Text('Delen'),
                          ),
                        ],
                        const SizedBox(height: _cardGap),
                      ],
                      if (!isPaired) ...[
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
                      Text(
                        'Account',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.edit),
                        title: const Text('Naam'),
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(rootContext).push(
                            MaterialPageRoute(
                              builder: (_) => ProfileNamePage(
                                fromSettings: true,
                                initialName: myName,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Huishouden',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      if (hasHousehold)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(Icons.child_care),
                          title: const Text('Kinderen'),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(rootContext).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    _KinderenPage(householdId: householdId),
                              ),
                            );
                          },
                        ),
                      if (hasHousehold)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(Icons.menu_book_outlined),
                          title: const Text('Logboek'),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(rootContext).push(
                              MaterialPageRoute(
                                builder: (_) => _LogboekPage(
                                  householdId: householdId,
                                  uid: myUid,
                                  myName: myName,
                                  otherName: otherName,
                                ),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'Info',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.privacy_tip_outlined),
                        title: const Text('Privacy'),
                        onTap: () {
                          Navigator.of(context).pop();
                          showDialog<void>(
                            context: rootContext,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Privacy in KiDu'),
                              content: SingleChildScrollView(
                                child: Text(
                                  'KiDu is gebouwd met één uitgangspunt: zo min mogelijk privacy-gevoelige data.\n\n'
                                  'Wat we wél gebruiken (alleen wat nodig is):\n'
                                  '• Je gekozen naam (zodat jullie elkaar herkennen)\n'
                                  '• Je Google-account (voor veilig inloggen)\n'
                                  '• Jullie gedeelde uitgaven in KiDu\n\n'
                                  'Wat KiDu níét vraagt of gebruikt:\n'
                                  '• Geen telefoonnummer\n'
                                  '• Geen toegang tot je contacten\n'
                                  '• Geen locatie\n'
                                  '• Geen agenda, microfoon of camera\n'
                                  '• Geen push-notificaties of "ping-gedrag"\n\n'
                                  'Delen met anderen?\n'
                                  '• Jullie gegevens zijn bedoeld voor jou en je co-parent in jullie huishouden (max. 2 accounts).\n'
                                  '• We delen geen gegevens voor marketingdoeleinden.\n'
                                  '• We verkopen je gegevens niet.\n\n'
                                  'Je houdt de controle:\n'
                                  '• Je kunt je naam altijd aanpassen.\n'
                                  '• Je kunt uitloggen wanneer je wilt.',
                                  style: Theme.of(ctx).textTheme.bodyMedium
                                      ?.copyWith(color: onSurface(ctx, a68)),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    Navigator.of(rootContext).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const PrivacyPolicyPage(),
                                      ),
                                    );
                                  },
                                  child: const Text(
                                    'Volledige privacyverklaring',
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('Sluiten'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.info_outline),
                        title: const Text('Over KiDu'),
                        onTap: () {
                          Navigator.of(context).pop();
                          showDialog<void>(
                            context: rootContext,
                            builder: (ctx) => AlertDialog(
                              title: const Text('KiDu'),
                              content: const Text(
                                'Rust in gedeelde kosten tussen co-parents.\n'
                                'Koppelen, bijhouden, afrekenen — zonder gedoe.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('Sluiten'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const Divider(height: 32),
                      if (kDebugMode)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(Icons.switch_account),
                          title: const Text('Wissel account'),
                          onTap: _switchBusy
                              ? null
                              : () {
                                  Navigator.of(context).pop();
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (!mounted) {
                                      return;
                                    }
                                    _switchAccount(rootContext);
                                  });
                                },
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
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

  Future<bool> _canWriteExpenseNow() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    try {
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns active (non-archived) children for the household, sorted by
  /// creation time. Returns empty list on any error so the dialog still opens.
  Future<List<_ChildItem>> _loadActiveChildren(String householdId) async {
    if (householdId.trim().isEmpty) return [];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/$householdId/children')
          .get();
      final docs =
          snap.docs
              .where(
                (d) =>
                    d.data()['isArchived'] != true &&
                    d.data()['isDeleted'] != true,
              )
              .toList()
            ..sort((a, b) {
              final aTs = a.data()['createdAt'];
              final bTs = b.data()['createdAt'];
              if (aTs is Timestamp && bTs is Timestamp) {
                return aTs.compareTo(bTs);
              }
              return 0;
            });
      return docs
          .map(
            (d) => _ChildItem(
              id: d.id,
              name: (d.data()['name'] as String?)?.trim() ?? '?',
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _createExpense({
    required String householdId,
    required String title,
    required int amountCents,
    String? note,
    String? coparentNameForPendingMessage,
    List<String>? childIds,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    try {
      final data = <String, dynamic>{
        'amountCents': amountCents,
        'currency': 'EUR',
        'title': title,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        if (childIds != null && childIds.isNotEmpty) 'childIds': childIds,
      };
      final ref = await FirebaseFirestore.instance
          .collection('households/$householdId/expenses')
          .add(data);
      String? noteErrMsg;
      final noteTrimmed = note?.trim();
      if (noteTrimmed != null && noteTrimmed.isNotEmpty) {
        try {
          await ref.collection('privateNotes').doc(uid).set({
            'note': noteTrimmed,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (noteErr) {
          if (kDebugMode) debugPrint('Private note write error: $noteErr');
          noteErrMsg = mapUserFacingError(
            noteErr,
            fallback: 'notitie niet opgeslagen.',
          );
        }
      }
      final expenseSnap = await ref.get(const GetOptions(source: Source.cache));
      final isPending = expenseSnap.metadata.hasPendingWrites;
      if (isPending) {
        final naam = (coparentNameForPendingMessage?.trim().isNotEmpty ?? false)
            ? coparentNameForPendingMessage!.trim()
            : 'je co-parent';
        _showSnackBar(
          'Uitgave wordt opgeslagen en is pas zichtbaar voor $naam zodra je weer online bent.',
        );
      } else {
        _showSnackBar(
          noteErrMsg != null
              ? 'Uitgave opgeslagen, $noteErrMsg'
              : 'Uitgave opgeslagen.',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Create expense error: $e');
      rethrow;
    }
  }

  Future<void> _openAddExpenseDialog(
    String householdId, {
    String? coparentName,
    List<_ChildItem> children = const [],
  }) async {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    var saving = false;
    var didShow = false;
    // Default selection: all active children (covers 0, 1, 2+ cases).
    var selectedChildIds = children.map((c) => c.id).toList();
    // When true, show individual chips even while all children are selected.
    var kidChipsExpanded = false;
    _freezeExpensesVN.value = true;

    try {
      didShow = true;
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              final screenW = MediaQuery.sizeOf(context).width;
              final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
              return Align(
                alignment: const Alignment(0, -0.15),
                child: SizedBox(
                  width: dialogW,
                  child: AlertDialog(
                    title: const Text('Nieuwe uitgave'),
                    content: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.55,
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
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
                            // "Voor wie?" section — only shown for 2+ children.
                            // Single-child: selectedChildIds already defaults to
                            // [child.id] so it is stored correctly without UI.
                            if (children.length > 1) ...[
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    'Voor wie?',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                  Builder(
                                    builder: (context) {
                                      final allSelected =
                                          selectedChildIds.length ==
                                          children.length;
                                      final showPill =
                                          allSelected && !kidChipsExpanded;
                                      return TextButton(
                                        onPressed: () => setLocalState(() {
                                          if (showPill) {
                                            kidChipsExpanded = true;
                                          } else {
                                            selectedChildIds = children
                                                .map((c) => c.id)
                                                .toList();
                                            kidChipsExpanded = false;
                                          }
                                        }),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: Text(
                                          showPill
                                              ? 'Selecteer'
                                              : 'Alle kinderen',
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              // Fixed-height area: dialog does not resize when
                              // toggling between the summary pill and chips.
                              SizedBox(
                                height: _kChildPickerHeight,
                                child: Builder(
                                  builder: (context) {
                                    final cs = Theme.of(context).colorScheme;
                                    final allSelected =
                                        selectedChildIds.length ==
                                        children.length;
                                    final showPill =
                                        allSelected && !kidChipsExpanded;

                                    if (showPill) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: cs.primary.withValues(
                                              alpha: 0.10,
                                            ),
                                            border: Border.all(
                                              color: cs.primary,
                                              width: 1.0,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                          ),
                                          child: Text(
                                            'Alle kinderen geselecteerd',
                                            style: TextStyle(
                                              color: cs.onSurface,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      );
                                    }

                                    // Individual chips — border width fixed at
                                    // 1.0; only color/bg change on selection.
                                    FilterChip kidChip({
                                      required Widget label,
                                      required bool selected,
                                      required ValueChanged<bool> onSelected,
                                    }) {
                                      return FilterChip(
                                        label: label,
                                        selected: selected,
                                        showCheckmark: false,
                                        backgroundColor: cs.surface,
                                        selectedColor: cs.primary.withValues(
                                          alpha: 0.10,
                                        ),
                                        side: BorderSide(
                                          color: selected
                                              ? cs.primary
                                              : cs.onSurface.withValues(
                                                  alpha: 0.22,
                                                ),
                                          width: 1.0,
                                        ),
                                        labelStyle: TextStyle(
                                          color: selected
                                              ? cs.onSurface
                                              : cs.onSurface.withValues(
                                                  alpha: 0.75,
                                                ),
                                          fontWeight: FontWeight.w500,
                                        ),
                                        onSelected: onSelected,
                                      );
                                    }

                                    return ClipRect(
                                      child: SingleChildScrollView(
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            ...children.map(
                                              (c) => kidChip(
                                                label: Text(c.name),
                                                selected: selectedChildIds
                                                    .contains(c.id),
                                                onSelected: (v) {
                                                  setLocalState(() {
                                                    if (v) {
                                                      selectedChildIds = [
                                                        ...selectedChildIds,
                                                        c.id,
                                                      ];
                                                    } else {
                                                      kidChipsExpanded = true;
                                                      selectedChildIds =
                                                          selectedChildIds
                                                              .where(
                                                                (id) =>
                                                                    id != c.id,
                                                              )
                                                              .toList();
                                                    }
                                                  });
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Annuleren'),
                      ),
                      ElevatedButton(
                        onPressed: saving
                            ? null
                            : () async {
                                final title = titleController.text.trim();
                                final amountCents = _tryParseEurToCents(
                                  amountController.text,
                                );
                                if (title.isEmpty) {
                                  _showSnackBar('Vul een titel in.');
                                  return;
                                }
                                if (amountCents == null || amountCents <= 0) {
                                  _showSnackBar('Vul een geldig bedrag in.');
                                  return;
                                }
                                if (selectedChildIds.isEmpty) {
                                  _showSnackBar('Selecteer minimaal één kind.');
                                  return;
                                }

                                setLocalState(() => saving = true);
                                if (!await _canWriteExpenseNow()) {
                                  _showSnackBar(
                                    'Je bent offline. Uitgave niet opgeslagen. Verbind met internet en probeer opnieuw.',
                                  );
                                  if (context.mounted) {
                                    setLocalState(() => saving = false);
                                  }
                                  return;
                                }
                                try {
                                  await _createExpense(
                                    householdId: householdId,
                                    title: title,
                                    amountCents: amountCents,
                                    note: noteController.text.trim().isEmpty
                                        ? null
                                        : noteController.text.trim(),
                                    coparentNameForPendingMessage: coparentName,
                                    childIds: selectedChildIds,
                                  );
                                  if (context.mounted) {
                                    await Future<void>.delayed(
                                      const Duration(milliseconds: 150),
                                    );
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  }
                                } catch (e) {
                                  debugPrint(
                                    'Create expense (dialog) error: $e',
                                  );
                                  _showSnackBar(
                                    mapUserFacingError(
                                      e,
                                      fallback:
                                          'Opslaan mislukt. Probeer opnieuw.',
                                    ),
                                  );
                                } finally {
                                  if (context.mounted) {
                                    setLocalState(() => saving = false);
                                  }
                                }
                              },
                        child: SizedBox(
                          width: 82,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              const Text('Opslaan'),
                              if (saving)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      if (mounted && didShow) {
        // Wait for the dialog pop animation to finish before unfreezing
        // the expenses list, so the dashboard stays stable during the
        // transition.
        await Future<void>.delayed(kThemeAnimationDuration);
      }
      if (mounted) _freezeExpensesVN.value = false;
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

  @override
  void dispose() {
    _addExpenseCheckBusyVN.dispose();
    _freezeExpensesVN.dispose();
    _addExpenseDialogOpenVN.dispose();
    super.dispose();
  }

  Future<void> _startSetup({bool silent = false}) async {
    if (!silent && _setupBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    if (!silent) setState(() => _setupBusy = true);

    try {
      final firestore = FirebaseFirestore.instance;
      final userRef = firestore.doc('users/$uid');

      final result = await firestore.runTransaction<Map<String, dynamic>>((
        transaction,
      ) async {
        final userSnap = await transaction.get(userRef);
        final userData = userSnap.data();
        final existingHouseholdId = (userData?['householdId'] as String?)
            ?.trim();

        if (existingHouseholdId != null && existingHouseholdId.isNotEmpty) {
          return {'alreadyExists': true, 'householdId': existingHouseholdId};
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

        transaction.set(userRef, {
          'householdId': householdRef.id,
          'setupCompletedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        return {'alreadyExists': false, 'householdId': householdRef.id};
      });

      final alreadyExists = result['alreadyExists'] == true;

      if (alreadyExists) {
        return;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Start setup error: $e');
      if (silent) {
        rethrow;
      } else {
        _showSnackBar(
          mapUserFacingError(e, fallback: 'Setup mislukt. Probeer opnieuw.'),
        );
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _setupBusy = false);
      }
    }
  }

  String _randomInviteCode(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(
      length,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
  }

  Future<String?> _generateInvite(
    String householdId, {
    bool silent = false,
  }) async {
    if (!silent && _inviteBusy) {
      return null;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return null;
    }

    if (!silent) setState(() => _inviteBusy = true);

    try {
      final firestore = FirebaseFirestore.instance;

      final membersSnap = await firestore
          .collection('households/$householdId/members')
          .limit(2)
          .get();
      if (membersSnap.size >= 2) {
        if (!silent) _showSnackBar('Household is al vol.');
        return null;
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
        if (kDebugMode) debugPrint('Generate invite error: $lastError');
        if (!silent) {
          _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
        }
        return null;
      }

      if (!silent && mounted) {
        setState(() {
          _inviteCode = createdCode;
        });
      }

      return createdCode;
    } catch (e) {
      if (kDebugMode) debugPrint('Generate invite error: $e');
      if (!silent) {
        _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
      }
      return null;
    } finally {
      if (!silent && mounted) {
        setState(() => _inviteBusy = false);
      }
    }
  }

  Future<void> _shareInviteCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      _showSnackBar('Geen invite code beschikbaar.');
      return;
    }
    try {
      final text =
          'Koppel met mij in KiDu.\nGebruik deze invite code: $trimmed';
      await Share.share(text);
    } catch (_) {
      _showSnackBar('Delen mislukt. Probeer opnieuw.');
    }
  }

  Future<void> _openInviteSheetFlow(String householdIdStr) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    var started = false;
    var loading = true;
    String? code;
    String? error;

    final didConfirm = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      isDismissible: true,
      enableDrag: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            if (!started) {
              started = true;
              Future.microtask(() async {
                String effectiveHouseholdId = householdIdStr.trim();
                try {
                  if (effectiveHouseholdId.isEmpty) {
                    await _startSetup(silent: true);
                    if (!sheetContext.mounted) return;
                    for (var i = 0; i < 10; i++) {
                      final userSnap = await FirebaseFirestore.instance
                          .doc('users/$uid')
                          .get();
                      final data = userSnap.data();
                      effectiveHouseholdId =
                          (data?['householdId'] as String?)?.trim() ?? '';
                      if (effectiveHouseholdId.isNotEmpty) break;
                      await Future<void>.delayed(
                        const Duration(milliseconds: 200),
                      );
                      if (!sheetContext.mounted) return;
                    }
                  }

                  if (effectiveHouseholdId.isEmpty) {
                    if (!sheetContext.mounted) return;
                    setModalState(() {
                      loading = false;
                      error = 'Kon geen code maken. Probeer opnieuw.';
                    });
                    return;
                  }

                  final generated = await _generateInvite(
                    effectiveHouseholdId,
                    silent: true,
                  );
                  if (!sheetContext.mounted) return;

                  final c = generated?.trim();
                  if (c == null || c.isEmpty) {
                    setModalState(() {
                      loading = false;
                      error = 'Kon geen code maken. Probeer opnieuw.';
                    });
                    return;
                  }

                  setModalState(() {
                    code = c;
                    loading = false;
                    error = null;
                  });
                } catch (_) {
                  if (!sheetContext.mounted) return;
                  setModalState(() {
                    loading = false;
                    error = 'Kon geen code maken. Probeer opnieuw.';
                  });
                }
              });
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: _pagePadding,
                  right: _pagePadding,
                  top: 8,
                  bottom:
                      _pagePadding +
                      MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Uitnodigingscode',
                        style: Theme.of(sheetContext).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: _cardGap),
                      if (loading) ...[
                        const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Code wordt gemaakt...',
                          textAlign: TextAlign.center,
                          style: Theme.of(sheetContext).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(sheetContext, a68)),
                        ),
                      ] else if (code != null) ...[
                        KiduCodePill(
                          code: code!,
                          onCopy: () async {
                            await Clipboard.setData(ClipboardData(text: code!));
                            _showSnackBar('Invite code gekopieerd.');
                          },
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: () => _shareInviteCode(code!),
                          icon: const Icon(Icons.share),
                          label: const Text('Delen'),
                        ),
                        const SizedBox(height: _cardGap),
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(true),
                            child: const Text('Klaar'),
                          ),
                        ),
                      ] else ...[
                        Text(
                          error ?? 'Kon geen code maken. Probeer opnieuw.',
                          style: Theme.of(sheetContext).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(sheetContext, a68)),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: () {
                              setModalState(() {
                                started = false;
                                loading = true;
                                code = null;
                                error = null;
                              });
                            },
                            child: const Text('Opnieuw'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (!mounted) return;
    if (didConfirm == true) {
      setState(() => _showWaiting = true);
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
      const SnackBar(
        content: Text('Uitgelogd. Kies een ander Google-account.'),
      ),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Avoid endless spinner if auth state flips during navigation/sign-out.
      return const AuthGate();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.doc('users/${user.uid}').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              centerTitle: true,
              title: Text(
                'KiDu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () => _openMenuSheet(
                    householdId: '',
                    myUid: user.uid,
                    otherName: null,
                    canInvite: false,
                    myName: null,
                  ),
                  icon: const Icon(Icons.more_horiz),
                  tooltip: 'Menu',
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: Text(
                  'Kon accountgegevens niet laden.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: onSurface(context, a62),
                    height: 1.35,
                  ),
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData ||
            snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              centerTitle: true,
              title: Text(
                'KiDu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            body: const SafeArea(
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final data = snapshot.data!.data();
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

        final householdIdStr = hasHousehold ? householdId.trim() : '';

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>?>(
          stream: hasHousehold
              ? FirebaseFirestore.instance
                    .collection('households/$householdIdStr/members')
                    .limit(2)
                    .snapshots()
              : Stream.value(null),
          builder: (context, membersSnapshot) {
            // Prevent "not linked" UI flash while member list is still loading
            // after re-login (hasHousehold=true but snapshot not ready yet).
            if (hasHousehold && membersSnapshot.hasError) {
              return Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  centerTitle: true,
                  title: Text(
                    'KiDu',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                body: SafeArea(
                  child: Center(
                    child: Text(
                      'Kon koppeling niet laden.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: onSurface(context, a62),
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              );
            }
            if (hasHousehold && !membersSnapshot.hasData) {
              return Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  centerTitle: true,
                  title: Text(
                    'KiDu',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                body: const SafeArea(
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }

            final memberDocs = hasHousehold && membersSnapshot.hasData
                ? membersSnapshot.data!.docs
                : <QueryDocumentSnapshot<Map<String, dynamic>>>[];
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
            final myDashboardName =
                (myProfileName != null && myProfileName.isNotEmpty)
                ? myProfileName
                : ((user.displayName != null &&
                          user.displayName!.trim().isNotEmpty)
                      ? user.displayName!.trim()
                      : 'Jij');

            if (canAddExpenses && _showWaiting) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() => _showWaiting = false);
              });
            }

            if (!canAddExpenses) {
              return PopScope(
                canPop: !_showWaiting,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop && _showWaiting) {
                    setState(() => _showWaiting = false);
                  }
                },
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(
                    centerTitle: true,
                    title: Text(
                      'KiDu',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    actions: [
                      IconButton(
                        onPressed: () => _openMenuSheet(
                          householdId: householdIdStr,
                          myUid: user.uid,
                          otherName: 'Co-parent',
                          canInvite: canInvite,
                          myName: myProfileName,
                        ),
                        icon: const Icon(Icons.more_horiz),
                        tooltip: 'Menu',
                      ),
                    ],
                  ),
                  floatingActionButton: null,
                  body: SafeArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return SingleChildScrollView(
                          padding: EdgeInsets.only(
                            bottom: MediaQuery.of(context).viewInsets.bottom,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight,
                            ),
                            child: IntrinsicHeight(
                              child: Padding(
                                padding: const EdgeInsets.all(_pagePadding),
                                child: Stack(
                                  children: [
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 520,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
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
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  _balanceRow(
                                                    label: 'Samen uitgegeven',
                                                    value: _formatEur(0),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    '$myDashboardName ${_formatEur(0)} • Co-parent ${_formatEur(0)}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a68,
                                                          ),
                                                          height: 1.3,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Divider(
                                                    height: 1,
                                                    color: outlineV(
                                                      context,
                                                      a45,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: _cardGap),
                                            KiduCard(
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
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    'Zodra je co-parent koppelt, zie je hier jullie uitgaven.',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a62,
                                                          ),
                                                          height: 1.35,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (!_showWaiting) ...[
                                              const SizedBox(height: _cardGap),
                                              KiduCard(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    Text(
                                                      'Je bent nog niet gekoppeld',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Text(
                                                      'Nog niet gekoppeld — nodig je co-parent uit om te starten.',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: onSurface(
                                                              context,
                                                              a62,
                                                            ),
                                                            height: 1.35,
                                                          ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    SizedBox(
                                                      height: 48,
                                                      child: ElevatedButton(
                                                        onPressed: () async {
                                                          if (_inviteSheetOpening) {
                                                            return;
                                                          }
                                                          if (_inviteBusy ||
                                                              _setupBusy) {
                                                            return;
                                                          }
                                                          _inviteSheetOpening =
                                                              true;
                                                          HapticFeedback.selectionClick();
                                                          try {
                                                            await _openInviteSheetFlow(
                                                              householdIdStr,
                                                            );
                                                          } finally {
                                                            _inviteSheetOpening =
                                                                false;
                                                          }
                                                        },
                                                        child: const Text(
                                                          'Co-parent uitnodigen',
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    SizedBox(
                                                      height: 48,
                                                      child: OutlinedButton(
                                                        onPressed: () {
                                                          Navigator.of(
                                                            context,
                                                          ).push(
                                                            MaterialPageRoute(
                                                              builder: (_) =>
                                                                  const SetupPage(),
                                                            ),
                                                          );
                                                        },
                                                        child: const Text(
                                                          'Ik heb een code',
                                                        ),
                                                      ),
                                                    ),
                                                    if (kDebugMode) ...[
                                                      const SizedBox(
                                                        height: 10,
                                                      ),
                                                      Center(
                                                        child: TextButton(
                                                          onPressed: _switchBusy
                                                              ? null
                                                              : () =>
                                                                    _switchAccount(
                                                                      context,
                                                                    ),
                                                          style:
                                                              TextButton.styleFrom(
                                                                foregroundColor:
                                                                    onSurface(
                                                                      context,
                                                                      a62,
                                                                    ),
                                                              ),
                                                          child: const Text(
                                                            'Wissel account',
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (_showWaiting) ...[
                                      const ModalBarrier(
                                        dismissible: false,
                                        color: Color(0x59000000),
                                      ),
                                      Align(
                                        alignment: const Alignment(0, 0.25),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 520,
                                            ),
                                            child: KiduCard(
                                              elevation: 8,
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  Text(
                                                    'Wachten op co-parent',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    'Je hebt de code gedeeld.\nZodra je co-parent koppelt, verschijnt het gedeelde overzicht automatisch.',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a68,
                                                          ),
                                                          height: 1.35,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 14),
                                                  SizedBox(
                                                    height: 48,
                                                    child: FilledButton(
                                                      onPressed: () {
                                                        setState(
                                                          () => _showWaiting =
                                                              false,
                                                        );
                                                      },
                                                      child: const Text(
                                                        'Terug',
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            }

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
                final myName = myFallbackName;
                final otherName = otherUid == null
                    ? 'Co-parent'
                    : (names[otherUid] ?? 'Co-parent');

                return Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(
                    centerTitle: true,
                    title: Text(
                      'KiDu',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    actions: canAddExpenses
                        ? [
                            IconButton(
                              onPressed: () => _openMenuSheet(
                                householdId: householdIdStr,
                                myUid: user.uid,
                                otherName: otherName,
                                canInvite: canInvite,
                                myName: myProfileName,
                              ),
                              icon: const Icon(Icons.more_horiz),
                              tooltip: 'Menu',
                            ),
                          ]
                        : [],
                  ),
                  floatingActionButton: canAddExpenses
                      ? ValueListenableBuilder<bool>(
                          valueListenable: _addExpenseDialogOpenVN,
                          builder: (context, dialogOpen, _) {
                            // Only the FAB subtree rebuilds when the dialog
                            // opens/closes — the rest of the dashboard is
                            // untouched.
                            if (dialogOpen) return const SizedBox.shrink();
                            return ValueListenableBuilder<bool>(
                              valueListenable: _addExpenseCheckBusyVN,
                              builder: (context, fabBusy, _) {
                                final bool addExpenseBusy =
                                    fabBusy ||
                                    _setupBusy ||
                                    _inviteBusy ||
                                    _switchBusy;

                                return FloatingActionButton(
                                  onPressed: addExpenseBusy
                                      ? null
                                      : () async {
                                          if (_addExpenseCheckBusyVN.value ||
                                              _addExpenseDialogOpenVN.value) {
                                            return;
                                          }
                                          // Capture before any awaits so the
                                          // local builder context isn't used
                                          // across async gaps.
                                          final messenger =
                                              ScaffoldMessenger.of(context);
                                          final nav = Navigator.of(context);
                                          _addExpenseCheckBusyVN.value = true;
                                          var didOpenDialog = false;
                                          try {
                                            if (!await _canWriteExpenseNow()) {
                                              _showSnackBar(
                                                'Je bent offline. Verbind met internet om een uitgave toe te voegen.',
                                              );
                                              return;
                                            }
                                            final kids =
                                                await _loadActiveChildren(
                                                  householdIdStr,
                                                );
                                            if (kids.isEmpty) {
                                              if (!mounted) return;
                                              messenger.hideCurrentSnackBar();
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: const Text(
                                                    'Voeg eerst een kind toe om een uitgave te registreren.',
                                                  ),
                                                  action: SnackBarAction(
                                                    label: 'Kinderen',
                                                    onPressed: () => nav.push(
                                                      MaterialPageRoute<void>(
                                                        builder: (_) =>
                                                            _KinderenPage(
                                                              householdId:
                                                                  householdIdStr,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                              return;
                                            }
                                            // Pre-load done: stop spinner and
                                            // hide FAB for the dialog duration.
                                            _addExpenseCheckBusyVN.value =
                                                false;
                                            if (!mounted) return;
                                            _addExpenseDialogOpenVN.value =
                                                true;
                                            didOpenDialog = true;
                                            await _openAddExpenseDialog(
                                              householdIdStr,
                                              coparentName: otherName,
                                              children: kids,
                                            );
                                          } finally {
                                            // Wait for the pop transition to
                                            // finish before restoring the FAB.
                                            if (didOpenDialog) {
                                              await Future<void>.delayed(
                                                kThemeAnimationDuration,
                                              );
                                            }
                                            _addExpenseDialogOpenVN.value =
                                                false;
                                            _addExpenseCheckBusyVN.value =
                                                false;
                                          }
                                        },
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: addExpenseBusy
                                        ? Center(
                                            child: SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer,
                                              ),
                                            ),
                                          )
                                        : const Icon(Icons.add, size: 24),
                                  ),
                                );
                              },
                            );
                          },
                        )
                      : null,
                  body: MediaQuery.removeViewInsets(
                    context: context,
                    removeBottom: true,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(_pagePadding),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: min(constraints.maxWidth, 520.0),
                                height: constraints.maxHeight,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _freezeExpensesVN,
                                  builder: (context, frozen, _) {
                                    return StreamBuilder<
                                      QuerySnapshot<Map<String, dynamic>>
                                    >(
                                      stream: FirebaseFirestore.instance
                                          .collection(
                                            'households/$householdIdStr/expenses',
                                          )
                                          .orderBy(
                                            'createdAt',
                                            descending: true,
                                          )
                                          .limit(20)
                                          .snapshots(
                                            includeMetadataChanges: true,
                                          ),
                                      builder: (context, expensesSnapshot) {
                                        if (expensesSnapshot.hasData &&
                                            !frozen) {
                                          _lastExpensesSnap =
                                              expensesSnapshot.data!;
                                        }
                                        final effectiveSnap =
                                            _lastExpensesSnap ??
                                            expensesSnapshot.data;
                                        if (expensesSnapshot.hasError &&
                                            effectiveSnap == null) {
                                          return const Text(
                                            'Kon uitgaven niet laden.',
                                          );
                                        }

                                        final docs =
                                            effectiveSnap?.docs ?? const [];

                                        var totalCents = 0;
                                        var myPaidCents = 0;
                                        for (final d in docs) {
                                          final e = d.data();
                                          final amountCents =
                                              (e['amountCents'] as num?)
                                                  ?.toInt() ??
                                              0;
                                          totalCents += amountCents;
                                          final createdBy =
                                              (e['createdBy'] as String?)
                                                  ?.trim();
                                          if (createdBy == user.uid) {
                                            myPaidCents += amountCents;
                                          }
                                        }
                                        final otherPaidCents =
                                            totalCents - myPaidCents;
                                        final halfFloor = totalCents ~/ 2;
                                        final remainder = totalCents % 2;
                                        final expectedMy =
                                            halfFloor +
                                            ((remainder == 1 &&
                                                    myPaidCents <
                                                        otherPaidCents)
                                                ? 1
                                                : 0);
                                        final settlementCents =
                                            myPaidCents - expectedMy;

                                        final absSettlement = settlementCents
                                            .abs();
                                        final settlementText =
                                            settlementCents > 0
                                            ? '$otherName betaalt jou ${_formatEur(absSettlement)}'
                                            : settlementCents < 0
                                            ? 'Jij betaalt $otherName ${_formatEur(absSettlement)}'
                                            : 'Jullie zijn in balans';

                                        String? lastActivityText;
                                        if (docs.isNotEmpty) {
                                          final first = docs.first;
                                          final e = first.data();
                                          final createdBy =
                                              (e['createdBy'] as String?)
                                                  ?.trim();
                                          final createdAt =
                                              e['createdAt'] as Timestamp?;
                                          final name = createdBy == user.uid
                                              ? myName
                                              : otherName;
                                          final timeStr = createdAt == null
                                              ? 'zojuist'
                                              : _formatRelativeNl(
                                                  createdAt.toDate(),
                                                );
                                          lastActivityText =
                                              'Laatste activiteit: $name · $timeStr';
                                        }

                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (lastActivityText != null) ...[
                                              Text(
                                                lastActivityText,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: onSurface(
                                                        context,
                                                        a60,
                                                      ),
                                                    ),
                                              ),
                                              const SizedBox(height: 8),
                                            ],
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
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  // Compact summary: replace three separate rows.
                                                  const SizedBox(height: 8),
                                                  _balanceRow(
                                                    label: 'Samen uitgegeven',
                                                    value: _formatEur(
                                                      totalCents,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    '$myName ${_formatEur(myPaidCents)} • $otherName ${_formatEur(otherPaidCents)}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a68,
                                                          ),
                                                          height: 1.3,
                                                        ),
                                                  ),
                                                  // Tighter section spacing for lower card height.
                                                  const SizedBox(height: 8),
                                                  Divider(
                                                    height: 1,
                                                    color: outlineV(
                                                      context,
                                                      a45,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  // Keep settlement as primary info.
                                                  Text(
                                                    settlementText,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: onSurface(
                                                            context,
                                                            a84,
                                                          ),
                                                          height: 1.3,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: _cardGap),
                                            Expanded(
                                              child: KiduCard(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
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
                                                    const SizedBox(height: 10),
                                                    Expanded(
                                                      child:
                                                          effectiveSnap == null
                                                          ? const Center(
                                                              child:
                                                                  CircularProgressIndicator(),
                                                            )
                                                          : docs.isEmpty
                                                          ? Align(
                                                              alignment:
                                                                  Alignment
                                                                      .topLeft,
                                                              child: Text(
                                                                canAddExpenses
                                                                    ? 'Nog geen uitgaven. Voeg er een toe met +.'
                                                                    : 'Nog geen uitgaven.',
                                                                style: Theme.of(context)
                                                                    .textTheme
                                                                    .bodyMedium
                                                                    ?.copyWith(
                                                                      color: onSurface(
                                                                        context,
                                                                        a62,
                                                                      ),
                                                                      height:
                                                                          1.35,
                                                                    ),
                                                              ),
                                                            )
                                                          : ListView.separated(
                                                              itemCount:
                                                                  docs.length,
                                                              separatorBuilder:
                                                                  (
                                                                    context,
                                                                    index,
                                                                  ) => Divider(
                                                                    height: 16,
                                                                    color:
                                                                        outlineV(
                                                                          context,
                                                                          a40,
                                                                        ),
                                                                  ),
                                                              itemBuilder: (context, index) {
                                                                final d =
                                                                    docs[index];
                                                                final e = d
                                                                    .data();
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

                                                                final who =
                                                                    createdBy ==
                                                                        user.uid
                                                                    ? myName
                                                                    : (otherUid !=
                                                                              null &&
                                                                          createdBy ==
                                                                              otherUid)
                                                                    ? otherName
                                                                    : 'Co-parent';
                                                                final isPending = d
                                                                    .metadata
                                                                    .hasPendingWrites;
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
                                                                        const nlMonths =
                                                                            <
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
                                                                            '${dt.day} ${nlMonths[dt.month - 1]}';
                                                                        return '$who • $shortDateTime';
                                                                      })();
                                                                final expChildIds =
                                                                    (e['childIds']
                                                                            as List?)
                                                                        ?.whereType<
                                                                          String
                                                                        >()
                                                                        .toList() ??
                                                                    const <
                                                                      String
                                                                    >[];

                                                                if (createdBy !=
                                                                    user.uid) {
                                                                  return Material(
                                                                    type: MaterialType.transparency,
                                                                    borderRadius: BorderRadius.circular(8),
                                                                    child: InkWell(
                                                                      borderRadius: BorderRadius.circular(8),
                                                                      highlightColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                                                                      splashColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                                                                      onTap: () {
                                                                        Navigator.of(
                                                                          context,
                                                                        ).push(
                                                                          MaterialPageRoute<
                                                                            void
                                                                          >(
                                                                            builder:
                                                                                (
                                                                                  context,
                                                                                ) => _ExpenseDetailPage(
                                                                                  householdId: householdIdStr,
                                                                                  expenseId: d.id,
                                                                                  uid: user.uid,
                                                                                  title: title,
                                                                                  amountCents: amountCents,
                                                                                  paidByName: who,
                                                                                  createdAt: createdAtDateTime,
                                                                                  isPending: isPending,
                                                                                  onManageNote: null,
                                                                                  childIds: expChildIds,
                                                                                ),
                                                                          ),
                                                                        );
                                                                      },
                                                                      child: ListTile(
                                                                        contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                                                                        dense: true,
                                                                        visualDensity:
                                                                            VisualDensity
                                                                                .compact,
                                                                        title: Text(
                                                                          title,
                                                                          maxLines:
                                                                              1,
                                                                          overflow:
                                                                              TextOverflow
                                                                                  .ellipsis,
                                                                        ),
                                                                        subtitle: Text(
                                                                          subtitleText,
                                                                          maxLines:
                                                                              1,
                                                                          overflow:
                                                                              TextOverflow
                                                                                  .ellipsis,
                                                                        ),
                                                                        trailing: Row(
                                                                          mainAxisSize:
                                                                              MainAxisSize
                                                                                  .min,
                                                                          children: [
                                                                            if (isPending)
                                                                              Tooltip(
                                                                                message:
                                                                                    'Nog niet gesynchroniseerd',
                                                                                child: Icon(
                                                                                  Icons.cloud_off,
                                                                                  size: 16,
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a50,
                                                                                  ),
                                                                                ),
                                                                              ),
                                                                            if (isPending)
                                                                              const SizedBox(
                                                                                width:
                                                                                    4,
                                                                              ),
                                                                            Text(
                                                                              _formatEur(
                                                                                amountCents,
                                                                              ),
                                                                              style:
                                                                                  Theme.of(
                                                                                    context,
                                                                                  ).textTheme.bodyMedium?.copyWith(
                                                                                    fontWeight: FontWeight.w700,
                                                                                  ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  );
                                                                }

                                                                return FutureBuilder<
                                                                  String?
                                                                >(
                                                                  key: ValueKey(
                                                                    'note_${d.id}_$_notesRefreshTick',
                                                                  ),
                                                                  future: _getNoteFuture(
                                                                    householdIdStr,
                                                                    d.id,
                                                                  ),
                                                                  builder:
                                                                      (
                                                                        context,
                                                                        noteSnap,
                                                                      ) {
                                                                        final note =
                                                                            noteSnap.data;
                                                                        final hasNote =
                                                                            note !=
                                                                                null &&
                                                                            note.isNotEmpty;

                                                                        Future<
                                                                          void
                                                                        >
                                                                        openNoteFlow() async {
                                                                          if (!await _canWriteExpenseNow()) {
                                                                            if (mounted) {
                                                                              final msg = hasNote
                                                                                  ? 'Je bent offline. Notitie wijzigen kan alleen met internet.'
                                                                                  : 'Je bent offline. Notitie toevoegen kan alleen met internet.';
                                                                              _showSnackBar(
                                                                                msg,
                                                                              );
                                                                            }
                                                                            return;
                                                                          }
                                                                          final snap = await FirebaseFirestore
                                                                              .instance
                                                                              .doc(
                                                                                'households/$householdIdStr/expenses/${d.id}/privateNotes/${user.uid}',
                                                                              )
                                                                              .get();
                                                                          final latestNote =
                                                                              ((snap.data()?['note']
                                                                                          as String?) ??
                                                                                      '')
                                                                                  .trim();
                                                                          await _openEditPrivateNoteDialog(
                                                                            householdId:
                                                                                householdIdStr,
                                                                            expenseId:
                                                                                d.id,
                                                                            uid:
                                                                                user.uid,
                                                                            initialNote:
                                                                                latestNote,
                                                                          );
                                                                        }

                                                                        return Material(
                                                                          type: MaterialType.transparency,
                                                                          borderRadius: BorderRadius.circular(8),
                                                                          child: InkWell(
                                                                            borderRadius: BorderRadius.circular(8),
                                                                            highlightColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                                                                            splashColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                                                                            onTap: () {
                                                                              Navigator.of(
                                                                                context,
                                                                              ).push(
                                                                                MaterialPageRoute<
                                                                                  void
                                                                                >(
                                                                                  builder:
                                                                                      (
                                                                                        context,
                                                                                      ) => _ExpenseDetailPage(
                                                                                        householdId: householdIdStr,
                                                                                        expenseId: d.id,
                                                                                        uid: user.uid,
                                                                                        title: title,
                                                                                        amountCents: amountCents,
                                                                                        paidByName: who,
                                                                                        createdAt: createdAtDateTime,
                                                                                        isPending: isPending,
                                                                                        onManageNote: openNoteFlow,
                                                                                        childIds: expChildIds,
                                                                                      ),
                                                                                ),
                                                                              );
                                                                            },
                                                                            child: ListTile(
                                                                              contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                                                                              dense:
                                                                                  true,
                                                                              visualDensity:
                                                                                  VisualDensity.compact,
                                                                              title: Text(
                                                                                title,
                                                                                maxLines:
                                                                                    1,
                                                                                overflow:
                                                                                    TextOverflow.ellipsis,
                                                                              ),
                                                                              subtitle: Column(
                                                                                crossAxisAlignment:
                                                                                    CrossAxisAlignment.start,
                                                                                mainAxisSize:
                                                                                    MainAxisSize.min,
                                                                                children: [
                                                                                  Text(
                                                                                    subtitleText,
                                                                                    maxLines: 1,
                                                                                    overflow: TextOverflow.ellipsis,
                                                                                  ),
                                                                                  Text(
                                                                                    hasNote
                                                                                        ? note
                                                                                        : '',
                                                                                    maxLines: 1,
                                                                                    overflow: TextOverflow.ellipsis,
                                                                                  ),
                                                                                ],
                                                                              ),
                                                                              trailing: Row(
                                                                                mainAxisSize:
                                                                                    MainAxisSize.min,
                                                                                mainAxisAlignment:
                                                                                    MainAxisAlignment.end,
                                                                                children: [
                                                                                  if (isPending)
                                                                                    Tooltip(
                                                                                      message: 'Nog niet gesynchroniseerd',
                                                                                      child: Icon(
                                                                                        Icons.cloud_off,
                                                                                        size: 16,
                                                                                        color: onSurface(
                                                                                          context,
                                                                                          a50,
                                                                                        ),
                                                                                      ),
                                                                                    ),
                                                                                  if (isPending)
                                                                                    const SizedBox(
                                                                                      width: 4,
                                                                                    ),
                                                                                  Text(
                                                                                    _formatEur(
                                                                                      amountCents,
                                                                                    ),
                                                                                    style:
                                                                                        Theme.of(
                                                                                          context,
                                                                                        ).textTheme.bodyMedium?.copyWith(
                                                                                          fontWeight: FontWeight.w700,
                                                                                        ),
                                                                                  ),
                                                                                ],
                                                                              ),
                                                                            ),
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
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
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

class _ExpenseDetailPage extends StatefulWidget {
  const _ExpenseDetailPage({
    required this.householdId,
    required this.expenseId,
    required this.uid,
    required this.title,
    required this.amountCents,
    required this.paidByName,
    required this.createdAt,
    required this.isPending,
    this.onManageNote,
    this.childIds = const [],
  });

  final String householdId;
  final String expenseId;
  final String uid;
  final String title;
  final int amountCents;
  final String paidByName;
  final DateTime? createdAt;
  final bool isPending;
  final Future<void> Function()? onManageNote;
  final List<String> childIds;

  /// Resolves child IDs to display names; falls back to "Verwijderd kind".
  static Future<List<String>> _resolveChildNames(
    String householdId,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return [];
    try {
      final snaps = await Future.wait(
        ids.map(
          (id) => FirebaseFirestore.instance
              .doc('households/$householdId/children/$id')
              .get(),
        ),
      );
      return snaps.map((s) {
        final name = (s.data()?['name'] as String?)?.trim();
        return (name != null && name.isNotEmpty) ? name : 'Verwijderd kind';
      }).toList();
    } catch (_) {
      return ids.map((_) => 'Verwijderd kind').toList();
    }
  }

  static String _formatEur(int cents) {
    final value = (cents / 100.0).toStringAsFixed(2);
    return '€$value';
  }

  static String _formatDateTime(DateTime? dt) {
    if (dt == null) return '—';
    const nlMonths = [
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
    return '${dt.day} ${nlMonths[dt.month - 1]} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  State<_ExpenseDetailPage> createState() => _ExpenseDetailPageState();
}

class _ExpenseDetailPageState extends State<_ExpenseDetailPage> {
  bool _noteActionBusy = false;

  void _handleBack() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: _handleBack),
          title: Text(
            'Uitgave',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Titel'),
                    subtitle: Text(widget.title),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Betaald door'),
                    subtitle: Text(widget.paidByName),
                  ),
                  if (widget.childIds.isNotEmpty)
                    FutureBuilder<List<String>>(
                      future: _ExpenseDetailPage._resolveChildNames(
                        widget.householdId,
                        widget.childIds,
                      ),
                      builder: (context, snap) {
                        if (!snap.hasData) return const SizedBox.shrink();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Voor'),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: snap.data!
                                  .map(
                                    (n) => Chip(
                                      label: Text(n),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        );
                      },
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Bedrag'),
                    subtitle: Text(
                      _ExpenseDetailPage._formatEur(widget.amountCents),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Datum/tijd'),
                    subtitle: Text(
                      _ExpenseDetailPage._formatDateTime(widget.createdAt),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Status'),
                    subtitle: widget.isPending
                        ? Row(
                            children: [
                              Icon(
                                Icons.cloud_off,
                                size: 18,
                                color: onSurface(context, a60),
                              ),
                              const SizedBox(width: 8),
                              const Text('Nog niet gesynchroniseerd'),
                            ],
                          )
                        : const Text('Gesynchroniseerd'),
                  ),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}/privateNotes/${widget.uid}',
                        )
                        .snapshots(),
                    builder: (context, snap) {
                      final data = snap.data?.data();
                      final note = (data?['note'] as String?)?.trim() ?? '';
                      final hasNoteLive = note.isNotEmpty;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasNoteLive)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Notitie'),
                              subtitle: Text(note),
                            ),
                          if (widget.onManageNote != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: FilledButton.icon(
                                onPressed: _noteActionBusy
                                    ? null
                                    : () async {
                                        if (_noteActionBusy) return;
                                        setState(() => _noteActionBusy = true);
                                        try {
                                          await widget.onManageNote!();
                                        } finally {
                                          if (mounted) {
                                            setState(
                                              () => _noteActionBusy = false,
                                            );
                                          }
                                        }
                                      },
                                icon: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: _noteActionBusy
                                      ? Center(
                                          child: SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onPrimary,
                                            ),
                                          ),
                                        )
                                      : Icon(
                                          hasNoteLive
                                              ? Icons.edit_note
                                              : Icons.note_add_outlined,
                                        ),
                                ),
                                label: Text(
                                  hasNoteLive
                                      ? 'Notitie wijzigen'
                                      : 'Notitie toevoegen',
                                ),
                              ),
                            ),
                        ],
                      );
                    },
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

// ────────────────────────────────────────────────────────────────────────────
// Logboek – read-only expense history with child filter
// ────────────────────────────────────────────────────────────────────────────

class _LogboekPage extends StatefulWidget {
  const _LogboekPage({
    required this.householdId,
    required this.uid,
    this.myName,
    this.otherName,
  });

  final String householdId;
  final String uid;
  final String? myName;
  final String? otherName;

  @override
  State<_LogboekPage> createState() => _LogboekPageState();
}

class _LogboekPageState extends State<_LogboekPage> {
  List<_ChildItem> _children = [];
  bool _childrenLoaded = false;
  String? _filterChildId; // null = alle, childId = selected child
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _expensesStream;
  bool _initialDataReady = false;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _expensesStream = FirebaseFirestore.instance
        .collection('households/${widget.householdId}/expenses')
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots();
    Future.wait([
      _loadChildren(),
      _expensesStream.first.then((_) {}).catchError((_) {}),
    ]).then((_) {
      if (mounted) setState(() => _initialDataReady = true);
    });
    _checkOffline();
  }

  Future<void> _checkOffline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      if (mounted) setState(() => _isOffline = true);
    }
  }

  Future<void> _loadChildren() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .get();
      final docs = snap.docs.toList()
        ..sort((a, b) {
          final aTs = a.data()['createdAt'];
          final bTs = b.data()['createdAt'];
          if (aTs is Timestamp && bTs is Timestamp) {
            return aTs.compareTo(bTs);
          }
          return 0;
        });
      final children = docs
          .map(
            (d) => _ChildItem(
              id: d.id,
              name: (d.data()['name'] as String?)?.trim() ?? '?',
            ),
          )
          .toList();
      if (mounted) {
        setState(() {
          _children = children;
          _childrenLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _childrenLoaded = true);
    }
  }

  bool _matchesFilter(Map<String, dynamic> data) {
    if (_filterChildId == null) return true;
    final ids =
        (data['childIds'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return ids.contains(_filterChildId);
  }

  static String _fmtEur(int cents) => '€${(cents / 100.0).toStringAsFixed(2)}';

  static String _fmtDate(DateTime? dt) {
    if (dt == null) return '—';
    const mo = [
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
    return '${dt.day} ${mo[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      centerTitle: true,
      leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      title: Text(
        'Logboek',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: appBar,
        body: !_initialDataReady
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isOffline)
                    Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Text(
                        'Offline — je ziet de laatst geladen gegevens.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a62),
                        ),
                      ),
                    ),
                  Expanded(child: _buildExpenseList(context)),
                ],
              ),
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context, Map<String?, int> counts) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (_children.length > 1)
            FilterChip(
              label: Text('Alle (${counts[null] ?? 0})'),
              selected: _filterChildId == null,
              onSelected: (_) => setState(() => _filterChildId = null),
            ),
          for (final child in _children) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text('${child.name} (${counts[child.id] ?? 0})'),
              selected: _filterChildId == child.id,
              onSelected: (v) =>
                  setState(() => _filterChildId = v ? child.id : null),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildExpenseList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _expensesStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mapUserFacingError(snap.error!)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final allDocs = snap.data!.docs;
        final counts = <String?, int>{
          null: allDocs.length,
          for (final child in _children)
            child.id: allDocs
                .where(
                  (d) =>
                      (d.data()['childIds'] as List?)?.contains(child.id) ==
                      true,
                )
                .length,
        };
        final docs = allDocs.where((d) => _matchesFilter(d.data())).toList();
        final Widget listWidget;
        if (docs.isEmpty) {
          listWidget = const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Geen uitgaven gevonden.'),
            ),
          );
        } else {
          listWidget = ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (context, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final d = docs[i];
            final e = d.data();
            final title = (e['title'] as String?)?.trim() ?? '(zonder naam)';
            final amountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
            final createdAtRaw = e['createdAt'];
            DateTime? createdAt;
            if (createdAtRaw is Timestamp) {
              createdAt = createdAtRaw.toDate().toLocal();
            } else if (createdAtRaw is DateTime) {
              createdAt = createdAtRaw.toLocal();
            }
            final childIds =
                (e['childIds'] as List?)?.whereType<String>().toList() ??
                const <String>[];
            final createdBy = (e['createdBy'] as String?)?.trim() ?? '';
            final paidByName = createdBy == widget.uid
                ? (widget.myName ?? 'Jij')
                : (widget.otherName ?? 'Co-parent');
            final nKids = childIds.length;
            final isFiltered = _filterChildId != null && nKids > 0;
            final displayCents = isFiltered
                ? (amountCents / nKids).round()
                : amountCents;
            final dateStr = _fmtDate(createdAt);
            final subtitleStr = isFiltered
                ? '$dateStr · Aandeel: 1/$nKids'
                : nKids > 0
                ? '$dateStr · ${nKids == 1 ? 'Voor: 1 kind' : 'Voor: $nKids kinderen'}'
                : dateStr;
            return Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                highlightColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                splashColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _ExpenseDetailPage(
                      householdId: widget.householdId,
                      expenseId: d.id,
                      uid: widget.uid,
                      title: title,
                      amountCents: amountCents,
                      paidByName: paidByName,
                      createdAt: createdAt,
                      isPending: false,
                      childIds: childIds,
                    ),
                  ),
                ),
                child: ListTile(
                  key: ValueKey(d.id),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    subtitleStr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: onSurface(context, a62)),
                  ),
                  trailing: Text(
                    _fmtEur(displayCents),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            );
          },
        );
        }
        return Column(
          children: [
            if (_childrenLoaded) _buildFilterRow(context, counts),
            Expanded(child: listWidget),
          ],
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Kinderen management screen
// ────────────────────────────────────────────────────────────────────────────

class _KinderenPage extends StatefulWidget {
  const _KinderenPage({required this.householdId});

  final String householdId;

  @override
  State<_KinderenPage> createState() => _KinderenPageState();
}

class _KinderenPageState extends State<_KinderenPage> {
  bool _busy = false;

  void _snackErr(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mapUserFacingError(e))));
  }

  void _snackInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _handleBack() => Navigator.of(context).pop();

  Future<void> _addChild({required List<String> activeNormalised}) async {
    // _AddChildDialog owns the TextEditingController; no disposal needed here.
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _AddChildDialog(activeNormalised: activeNormalised),
    );
    if (newName == null || newName.isEmpty) return;
    setState(() => _busy = true);
    try {
      final normNew = newName.trim().toLowerCase();
      final allSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .get();
      final deleted = allSnap.docs.where((d) {
        final data = d.data();
        if (data['isDeleted'] != true) return false;
        final stored = ((data['name'] as String?) ?? '').trim().toLowerCase();
        return stored == normNew;
      }).toList();

      if (deleted.isNotEmpty) {
        await deleted.first.reference.update({
          'isDeleted': false,
          'isArchived': false,
          'deletedAt': FieldValue.delete(),
        });
        _snackInfo('Bestaand kind hersteld.');
        return;
      }

      await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .add({
            'name': newName,
            'createdAt': FieldValue.serverTimestamp(),
            'createdBy': FirebaseAuth.instance.currentUser?.uid ?? '',
            'isArchived': false,
            'isDeleted': false,
          });
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameChild(
    String docId,
    String currentName, {
    required List<String> activeNormalisedExcludingSelf,
  }) async {
    // _RenameChildDialog owns the TextEditingController; no disposal needed here.
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameChildDialog(
        currentName: currentName,
        activeNormalisedExcludingSelf: activeNormalisedExcludingSelf,
      ),
    );
    if (newName == null || newName.isEmpty) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'name': newName, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archiveChild(String docId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kind archiveren?'),
        content: Text('$name wordt verborgen bij nieuwe uitgaven.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Archiveren'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'isArchived': true, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreChild(String docId) async {
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'isArchived': false, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _softDeleteChild(String docId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Definitief verwijderen?'),
        content: Text(
          '"$name" wordt definitief verwijderd. '
          'Blijft bewaard voor oude uitgaven.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Verwijderen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({
            'isDeleted': true,
            'deletedAt': Timestamp.now(),
            'updatedAt': Timestamp.now(),
          });
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('households/${widget.householdId}/children')
            .orderBy('createdAt')
            .snapshots(),
        builder: (context, snap) {
          final appBar = AppBar(
            centerTitle: true,
            leading: BackButton(onPressed: _handleBack),
            title: Text(
              'Kinderen',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          );

          if (snap.hasError) {
            return Scaffold(
              appBar: appBar,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(mapUserFacingError(snap.error!)),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return Scaffold(
              appBar: appBar,
              body: const Center(child: CircularProgressIndicator()),
            );
          }

          final allDocs = snap.data!.docs;

          // Active: not archived AND not soft-deleted.
          final active = allDocs
              .where(
                (d) =>
                    d.data()['isArchived'] != true &&
                    d.data()['isDeleted'] != true,
              )
              .toList();

          // Archived: archived but not yet soft-deleted.
          final archived = allDocs
              .where(
                (d) =>
                    d.data()['isArchived'] == true &&
                    d.data()['isDeleted'] != true,
              )
              .toList();

          // Lower-cased active names for duplicate-name validation.
          final activeNormalised = active
              .map(
                (d) =>
                    ((d.data()['name'] as String?)?.trim() ?? '').toLowerCase(),
              )
              .toList();

          final atMax = active.length >= 7;

          final fab = FloatingActionButton(
            onPressed: _busy
                ? null
                : atMax
                ? () => _snackInfo(
                    'Maximaal 7 actieve kinderen. Archiveer eerst een kind.',
                  )
                : () => _addChild(activeNormalised: activeNormalised),
            tooltip: atMax ? 'Maximaal 7 actieve kinderen' : 'Kind toevoegen',
            backgroundColor: atMax
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : null,
            foregroundColor: atMax ? onSurface(context, a62) : null,
            child: const Icon(Icons.add),
          );

          // Flat list: active section, then archived section.
          final items = <Widget>[];

          if (active.isNotEmpty) {
            items.add(
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  'Actief',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            );
            for (int i = 0; i < active.length; i++) {
              final d = active[i];
              final name = (d.data()['name'] as String?)?.trim() ?? '?';
              // Active names excluding this child (for rename duplicate check).
              final othersNormalised = active
                  .where((o) => o.id != d.id)
                  .map(
                    (o) => ((o.data()['name'] as String?)?.trim() ?? '')
                        .toLowerCase(),
                  )
                  .toList();
              if (i > 0) items.add(const Divider(height: 1));
              items.add(
                ListTile(
                  title: Text(name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Naam wijzigen',
                        onPressed: _busy
                            ? null
                            : () => _renameChild(
                                d.id,
                                name,
                                activeNormalisedExcludingSelf: othersNormalised,
                              ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.archive_outlined, size: 20),
                        tooltip: 'Archiveren',
                        onPressed: _busy
                            ? null
                            : () => _archiveChild(d.id, name),
                      ),
                    ],
                  ),
                ),
              );
            }
          }

          if (archived.isNotEmpty) {
            items.add(
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 4),
                child: Text(
                  'Archief',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            );
            for (int i = 0; i < archived.length; i++) {
              final d = archived[i];
              final name = (d.data()['name'] as String?)?.trim() ?? '?';
              if (i > 0) items.add(const Divider(height: 1));
              items.add(
                ListTile(
                  title: Text(
                    name,
                    style: TextStyle(color: onSurface(context, a62)),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.unarchive_outlined, size: 20),
                        tooltip: 'Herstellen',
                        onPressed: _busy ? null : () => _restoreChild(d.id),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        tooltip: 'Definitief verwijderen',
                        onPressed: _busy
                            ? null
                            : () => _softDeleteChild(d.id, name),
                      ),
                    ],
                  ),
                ),
              );
            }
          }

          return Scaffold(
            appBar: appBar,
            floatingActionButton: fab,
            body: items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Nog geen kinderen. Voeg er een toe met +.'),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    children: items,
                  ),
          );
        },
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Add-child dialog
//
// Owns its TextEditingController via initState/dispose so the controller is
// always torn down by Flutter's widget lifecycle, never while EditableText is
// still mounted during the dialog's dismiss animation or IME hide.
// ────────────────────────────────────────────────────────────────────────────

class _AddChildDialog extends StatefulWidget {
  const _AddChildDialog({required this.activeNormalised});

  final List<String> activeNormalised;

  @override
  State<_AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends State<_AddChildDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final isDuplicate =
        text.isNotEmpty && widget.activeNormalised.contains(text.toLowerCase());
    final canAdd = text.isNotEmpty && !isDuplicate;

    return AlertDialog(
      title: const Text('Kind toevoegen'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (canAdd) Navigator.of(context).pop(_controller.text.trim());
        },
        decoration: InputDecoration(
          labelText: 'Naam',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          errorText: isDuplicate ? 'Naam bestaat al' : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        ElevatedButton(
          onPressed: canAdd
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Toevoegen'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Rename-child dialog
//
// Owns its TextEditingController so Flutter disposes it as part of the normal
// widget lifecycle — never while EditableText is still mounted during the
// dialog's dismiss animation or IME hide.
// ────────────────────────────────────────────────────────────────────────────

class _RenameChildDialog extends StatefulWidget {
  const _RenameChildDialog({
    required this.currentName,
    required this.activeNormalisedExcludingSelf,
  });

  final String currentName;
  final List<String> activeNormalisedExcludingSelf;

  @override
  State<_RenameChildDialog> createState() => _RenameChildDialogState();
}

class _RenameChildDialogState extends State<_RenameChildDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final isSame = text == widget.currentName.trim();
    final isDuplicate =
        text.isNotEmpty &&
        !isSame &&
        widget.activeNormalisedExcludingSelf.contains(text.toLowerCase());
    final canSave = text.isNotEmpty && !isSame && !isDuplicate;

    return AlertDialog(
      title: const Text('Naam wijzigen'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (canSave) Navigator.of(context).pop(_controller.text.trim());
        },
        decoration: InputDecoration(
          labelText: 'Naam',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          errorText: isDuplicate ? 'Naam bestaat al' : null,
          helperText: isSame && text.isNotEmpty ? 'Naam is ongewijzigd' : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        ElevatedButton(
          onPressed: canSave
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Opslaan'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

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
    final effectiveBorderColor = borderColor ?? outlineV(context, a55);

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
        color: Color.alphaBlend(cs.primary.withValues(alpha: a06), cs.surface),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: outlineV(context, a45)),
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
  String? _joinInlineHint;

  Future<void> _showJoinSuccessAndClose() async {
    if (!mounted) return;
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Join success',
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, a1, a2) => const _JoinSuccessOverlay(),
    );

    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    // Close overlay, then close setup page.
    Navigator.of(context, rootNavigator: true).pop();
    Navigator.of(context).pop();
  }

  Future<void> _joinHousehold() async {
    if (_joinBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    final code = _inviteController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _joinInlineHint = 'Vul een invite code in.');
      return;
    }

    setState(() {
      _joinBusy = true;
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

      final targetHouseholdId = (inviteData?['householdId'] as String?)?.trim();
      if (targetHouseholdId == null || targetHouseholdId.isEmpty) {
        throw StateError('Invite is ongeldig.');
      }

      final userSnap = await userRef.get();
      final userData = userSnap.data();
      final currentHouseholdId = (userData?['householdId'] as String?)?.trim();

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
        if (membersSnap.docs.length != 1 || membersSnap.docs.first.id != uid) {
          throw StateError(
            'Wisselen kan alleen als je huidige household leeg is.',
          );
        }
        if (expensesSnap.docs.isNotEmpty) {
          throw StateError(
            'Wisselen kan alleen als je huidige household leeg is.',
          );
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
        final hId = (inviteRecheck.data()?['householdId'] as String?)?.trim();
        if (hId == null || hId.isEmpty) {
          throw StateError('Invite is ongeldig.');
        }

        transaction.set(userRef, {
          'householdId': hId,
          'displayName': FirebaseAuth.instance.currentUser!.displayName,
          'email': FirebaseAuth.instance.currentUser!.email,
          'photoUrl': FirebaseAuth.instance.currentUser!.photoURL,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final targetMemberRef = firestore.doc('households/$hId/members/$uid');
        transaction.set(targetMemberRef, {
          'role': 'parent',
          'joinedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        transaction.set(inviteRef, {
          'usedBy': uid,
          'usedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (currentHouseholdId != null &&
            currentHouseholdId.isNotEmpty &&
            currentHouseholdId != targetHouseholdId) {
          final oldMemberRef = firestore.doc(
            'households/$currentHouseholdId/members/$uid',
          );
          transaction.delete(oldMemberRef);
        }
      });

      // TODO(re-enable after rules alignment): household isConnected update
      // requires allow update on households; temporarily disabled.
      // await firestore.doc('households/$targetHouseholdId').set(
      //   {'isConnected': true},
      //   SetOptions(merge: true),
      // );

      if (mounted) {
        await _showJoinSuccessAndClose();
      }
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('Je zit al in dit household')) {
        if (mounted) {
          setState(() {
            _joinInlineHint =
                'Je hoeft deze code niet zelf in te voeren. Deel \'m met je co-parent.';
          });
        }
      } else {
        if (kDebugMode) debugPrint('Join household error: $e');
        if (mounted) {
          setState(() {
            _joinInlineHint =
                'Koppelen lukt nu niet. Controleer de code en probeer opnieuw.';
          });
        }
      }
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
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Koppelen',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: uid == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Niet ingelogd.', textAlign: TextAlign.center),
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
                      const SizedBox(height: 24),
                      TextField(
                        controller: _inviteController,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (_) =>
                            setState(() => _joinInlineHint = null),
                        decoration: const InputDecoration(
                          labelText: 'Koppelcode',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_joinInlineHint != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _joinInlineHint!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: onSurface(context, a62),
                                height: 1.35,
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _joinBusy ? null : _joinHousehold,
                        child: Text(
                          _joinBusy
                              ? 'Bezig...'
                              : (hasHousehold ? 'Verbinden' : 'Koppelen'),
                        ),
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

class _JoinSuccessOverlay extends StatelessWidget {
  const _JoinSuccessOverlay();

  @override
  Widget build(BuildContext context) {
    return const PopScope(
      canPop: false,
      child: Material(
        color: _kSuccessGreen,
        child: Center(
          child: Icon(
            Icons.check_circle_rounded,
            size: 96,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
