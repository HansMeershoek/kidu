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
const double a18 = 0.18;
const double a40 = 0.40;
const double a45 = 0.45;
const double a50 = 0.50;
const double a55 = 0.55;
const double a60 = 0.60;
const double a62 = 0.62;
const double a66 = 0.66;
const double a68 = 0.68;
const double a72 = 0.72;
const double a84 = 0.84;
const double a85 = 0.85;

/// Calm green for success overlays (e.g. join/connect confirmation).
const Color _kSuccessGreen = Color(0xFF2E7D32);

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
  ).copyWith(
    surface: Colors.white,
    surfaceTint: Colors.transparent,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: appBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: appBg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
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
  const ProfileNamePage({super.key, this.fromSettings = false});

  final bool fromSettings;

  @override
  State<ProfileNamePage> createState() => _ProfileNamePageState();
}

class _ProfileNamePageState extends State<ProfileNamePage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _nameInlineHint;

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
              Text(
                'Welke naam wil je gebruiken?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
                  if (_nameInlineHint != null) setState(() => _nameInlineHint = null);
                },
                decoration: const InputDecoration(border: OutlineInputBorder()),
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
  bool _switchBusy = false;
  bool _expenseBusy = false;
  String? _inviteCode;
  bool _showWaiting = false;
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
      setState(() => _notesRefreshTick++);
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
            final email = FirebaseAuth.instance.currentUser?.email?.trim();

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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (email != null && email.isNotEmpty)
                        Text(
                          'Ingelogd als: $email',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: onSurface(context, a62),
                                height: 1.35,
                              ),
                        ),
                      if (isPaired)
                        Text(
                          'Verbonden met: $effectiveOtherName',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: onSurface(context, a68),
                                    height: 1.35,
                                  ),
                        )
                      else
                        Text(
                          'Koppel met je co-parent om samen kosten te delen.',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.edit),
                        title: const Text('Naam wijzigen'),
                        subtitle: Text(
                          'Wijzig hoe je zichtbaar bent in KiDu',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: onSurface(context, a62)),
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(rootContext).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const ProfileNamePage(fromSettings: true),
                            ),
                          );
                        },
                      ),
                      Text(
                        'Info',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
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
                      ListTile(
                        contentPadding: EdgeInsets.zero,
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
                                  style: Theme.of(ctx)
                                      .textTheme
                                      .bodyMedium
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
                      const Divider(height: 24),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
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

  Future<void> _createExpense({
    required String householdId,
    required String title,
    required int amountCents,
    String? note,
    String? coparentNameForPendingMessage,
  }) async {
    if (_expenseBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
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
    } finally {
      if (mounted) {
        setState(() => _expenseBusy = false);
      }
    }
  }

  Future<void> _openAddExpenseDialog(
    String householdId, {
    String? coparentName,
  }) async {
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
                                );
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              } catch (e) {
                                debugPrint('Create expense (dialog) error: $e');
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
      _showSnackBar(
        mapUserFacingError(e, fallback: 'Setup mislukt. Probeer opnieuw.'),
      );
    } finally {
      if (mounted) {
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

  Future<void> _generateInvite(String householdId) async {
    if (_inviteBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
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
        if (kDebugMode) debugPrint('Generate invite error: $lastError');
        _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
        return;
      }

      if (mounted) {
        setState(() {
          _inviteCode = createdCode;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Generate invite error: $e');
      _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
    } finally {
      if (mounted) {
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

  void _openInviteSheetOnly(BuildContext context, String code) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: _pagePadding,
              right: _pagePadding,
              top: 8,
              bottom: _pagePadding + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Uitnodigingscode',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: _cardGap),
                  KiduCodePill(
                    code: code,
                    onCopy: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      _showSnackBar('Invite code gekopieerd.');
                    },
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _shareInviteCode(code),
                    icon: const Icon(Icons.share),
                    label: const Text('Delen'),
                  ),
                  const SizedBox(height: _cardGap),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        if (!mounted) return;
                        setState(() => _showWaiting = true);
                      },
                      child: const Text('Klaar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _onCoParentUitnodigen(String householdIdStr) async {
    if (_inviteBusy || _setupBusy) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    String effectiveHouseholdId = householdIdStr;

    if (effectiveHouseholdId.isEmpty) {
      await _startSetup();
      if (!mounted) return;
      for (var i = 0; i < 10; i++) {
        final userSnap = await FirebaseFirestore.instance.doc('users/$uid').get();
        final data = userSnap.data();
        effectiveHouseholdId =
            (data?['householdId'] as String?)?.trim() ?? '';
        if (effectiveHouseholdId.isNotEmpty) {
          break;
        }
        if (kDebugMode) {
          debugPrint('resolve householdId retry=$i still empty');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (effectiveHouseholdId.isEmpty) {
        _showSnackBar('Kon geen huishouden aanmaken. Probeer opnieuw.');
        return;
      }
    }

    await _generateInvite(effectiveHouseholdId);
    if (!mounted) return;
    if (_inviteCode != null && _inviteCode!.trim().isNotEmpty) {
      setState(() {
        _showWaiting = false;
      });
      _openInviteSheetOnly(context, _inviteCode!.trim());
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
        if (snapshot.hasError) {
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
              child: Center(
                child: CircularProgressIndicator(),
              ),
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

        final householdIdStr =
            hasHousehold ? householdId.trim() : '';

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
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
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
            final myDashboardName = (myProfileName != null &&
                    myProfileName.isNotEmpty)
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
                  actions: [
                    IconButton(
                      onPressed: () => _openMenuSheet(
                        householdId: householdIdStr,
                        myUid: user.uid,
                        otherName: 'Co-parent',
                        canInvite: canInvite,
                      ),
                      icon: const Icon(Icons.more_horiz),
                      tooltip: 'Menu',
                    ),
                  ],
                ),
                floatingActionButton: null,
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(_pagePadding),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                        const SizedBox(height: 8),
                                        _balanceRow(
                                          label: 'Samen uitgegeven',
                                          value: _formatEur(0),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          '$myDashboardName ${_formatEur(0)} • Co-parent ${_formatEur(0)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: onSurface(context, a68),
                                                height: 1.3,
                                              ),
                                        ),
                                        const SizedBox(height: 8),
                                        Divider(
                                          height: 1,
                                          color: outlineV(context, a45),
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
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          'Zodra je co-parent koppelt, zie je hier jullie uitgaven.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: onSurface(context, a62),
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
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(
                                            'Je bent nog niet gekoppeld',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Nog niet gekoppeld — nodig je co-parent uit om te starten.',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: onSurface(context, a62),
                                                  height: 1.35,
                                                ),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            height: 48,
                                            child: ElevatedButton(
                                              onPressed:
                                                  (_inviteBusy || _setupBusy)
                                                  ? null
                                                  : () {
                                                      HapticFeedback
                                                          .selectionClick();
                                                      _onCoParentUitnodigen(
                                                        householdIdStr,
                                                      );
                                                    },
                                              child: Text(
                                                (_inviteBusy || _setupBusy)
                                                    ? 'Bezig...'
                                                    : 'Co-parent uitnodigen',
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            height: 48,
                                            child: OutlinedButton(
                                              onPressed: () {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        const SetupPage(),
                                                  ),
                                                );
                                              },
                                              child: const Text('Ik heb een code'),
                                            ),
                                          ),
                                          if (kDebugMode) ...[
                                            const SizedBox(height: 10),
                                            Center(
                                              child: TextButton(
                                                onPressed: _switchBusy
                                                    ? null
                                                    : () =>
                                                          _switchAccount(context),
                                                style: TextButton.styleFrom(
                                                  foregroundColor:
                                                      onSurface(context, a62),
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
                        ),
                        if (_showWaiting) ...[
                          const ModalBarrier(
                            dismissible: false,
                            color: Color(0x59000000),
                          ),
                          Align(
                            alignment: const Alignment(0, 0.25),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: KiduCard(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'Wachten op co-parent',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Je hebt de code gedeeld.\nZodra je co-parent koppelt, verschijnt het gedeelde overzicht automatisch.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: onSurface(context, a68),
                                            height: 1.35,
                                          ),
                                    ),
                                    const SizedBox(height: 14),
                                    SizedBox(
                                      height: 48,
                                      child: FilledButton(
                                        onPressed: () {
                                          setState(() => _showWaiting = false);
                                        },
                                        child: const Text('Terug'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
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
                final myName = names[user.uid] ?? myFallbackName;
                final otherName = otherUid == null
                    ? 'Co-parent'
                    : (names[otherUid] ?? 'Co-parent');

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
                    actions: canAddExpenses
                        ? [
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
                          ]
                        : [],
                  ),
                  floatingActionButton: canAddExpenses
                      ? FloatingActionButton(
                          onPressed: _expenseBusy
                              ? null
                              : () async {
                                  if (!await _canWriteExpenseNow()) {
                                    _showSnackBar(
                                      'Je bent offline. Verbind met internet om een uitgave toe te voegen.',
                                    );
                                    return;
                                  }
                                  _openAddExpenseDialog(
                                    householdIdStr,
                                    coparentName: otherName,
                                  );
                                },
                          child: const Icon(Icons.add),
                        )
                      : null,
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
                              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                                stream: FirebaseFirestore.instance
                                    .collection(
                                      'households/$householdIdStr/expenses',
                                    )
                                    .orderBy('createdAt', descending: true)
                                    .limit(20)
                                    .snapshots(includeMetadataChanges: true),
                                builder: (context, expensesSnapshot) {
                                  if (expensesSnapshot.hasError) {
                                    return const Text(
                                      'Kon uitgaven niet laden.',
                                    );
                                  }

                                  final docs =
                                      expensesSnapshot.data?.docs ?? const [];

                                  var totalCents = 0;
                                  var myPaidCents = 0;
                                  for (final d in docs) {
                                    final e = d.data();
                                    final amountCents =
                                        (e['amountCents'] as num?)?.toInt() ??
                                        0;
                                    totalCents += amountCents;
                                    final createdBy =
                                        (e['createdBy'] as String?)?.trim();
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
                                              myPaidCents < otherPaidCents)
                                          ? 1
                                          : 0);
                                  final settlementCents =
                                      myPaidCents - expectedMy;

                                  final absSettlement = settlementCents.abs();
                                  final settlementText = settlementCents > 0
                                      ? '$otherName betaalt jou ${_formatEur(absSettlement)}'
                                      : settlementCents < 0
                                      ? 'Jij betaalt $otherName ${_formatEur(absSettlement)}'
                                      : 'Jullie zijn in balans';

                                  String? lastActivityText;
                                  if (docs.isNotEmpty) {
                                    final first = docs.first;
                                    final e = first.data();
                                    final createdBy =
                                        (e['createdBy'] as String?)?.trim();
                                    final createdAt =
                                        e['createdAt'] as Timestamp?;
                                    final name = createdBy == user.uid
                                        ? myName
                                        : otherName;
                                    final timeStr = createdAt == null
                                        ? 'zojuist'
                                        : _formatRelativeNl(createdAt.toDate());
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
                                                color: onSurface(context, a60),
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
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            // Compact summary: replace three separate rows.
                                            const SizedBox(height: 8),
                                            _balanceRow(
                                              label: 'Samen uitgegeven',
                                              value: _formatEur(totalCents),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              '$myName ${_formatEur(myPaidCents)} • $otherName ${_formatEur(otherPaidCents)}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: onSurface(context, a68),
                                                    height: 1.3,
                                                  ),
                                            ),
                                            // Tighter section spacing for lower card height.
                                            const SizedBox(height: 8),
                                            Divider(
                                              height: 1,
                                              color: outlineV(context, a45),
                                            ),
                                            const SizedBox(height: 8),
                                            // Keep settlement as primary info.
                                            Text(
                                              settlementText,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
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
                                                          canAddExpenses
                                                              ? 'Nog geen uitgaven. Voeg er een toe met +.'
                                                              : 'Nog geen uitgaven.',
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .bodyMedium
                                                              ?.copyWith(
                                                                color:
                                                                    onSurface(
                                                                      context,
                                                                      a62,
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
                                                                  color:
                                                                      outlineV(
                                                                        context,
                                                                        a40,
                                                                      ),
                                                                ),
                                                        itemBuilder: (context, index) {
                                                          final d = docs[index];
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
                                                                      <String>[
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

                                                          if (createdBy !=
                                                              user.uid) {
                                                            return ListTile(
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              onTap: () {
                                                                Navigator.of(
                                                                  context,
                                                                ).push(
                                                                  MaterialPageRoute<
                                                                    void
                                                                  >(
                                                                    builder: (context) => _ExpenseDetailPage(
                                                                      householdId:
                                                                          householdIdStr,
                                                                      expenseId:
                                                                          d.id,
                                                                      uid: user
                                                                          .uid,
                                                                      title:
                                                                          title,
                                                                      amountCents:
                                                                          amountCents,
                                                                      paidByName:
                                                                          who,
                                                                      createdAt:
                                                                          createdAtDateTime,
                                                                      isPending:
                                                                          isPending,
                                                                      onManageNote:
                                                                          null,
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                              title: Text(
                                                                title,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                              subtitle: Text(
                                                                subtitleText,
                                                                maxLines: 1,
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
                                                                        Icons
                                                                            .cloud_off,
                                                                        size:
                                                                            16,
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
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .bodyMedium
                                                                        ?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w700,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                          }

                                                          return FutureBuilder<
                                                            String?
                                                          >(
                                                            key: ValueKey(
                                                              'note_${d.id}_$_notesRefreshTick',
                                                            ),
                                                            future: _loadMyPrivateNote(
                                                              householdId:
                                                                  householdIdStr,
                                                              expenseId: d.id,
                                                              uid: user.uid,
                                                            ),
                                                            builder: (context, noteSnap) {
                                                              final note =
                                                                  noteSnap.data;
                                                              final hasNote =
                                                                  note !=
                                                                      null &&
                                                                  note.isNotEmpty;

                                                              Future<void>
                                                              openNoteFlow() async {
                                                                if (!await _canWriteExpenseNow()) {
                                                                  if (mounted) {
                                                                    final msg =
                                                                        hasNote
                                                                        ? 'Je bent offline. Notitie wijzigen kan alleen met internet.'
                                                                        : 'Je bent offline. Notitie toevoegen kan alleen met internet.';
                                                                    _showSnackBar(
                                                                      msg,
                                                                    );
                                                                  }
                                                                  return;
                                                                }
                                                                final snap =
                                                                    await FirebaseFirestore
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
                                                                  uid: user.uid,
                                                                  initialNote:
                                                                      latestNote,
                                                                );
                                                              }

                                                              return ListTile(
                                                                contentPadding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                dense: true,
                                                                visualDensity:
                                                                    VisualDensity
                                                                        .compact,
                                                                onTap: () {
                                                                  Navigator.of(
                                                                    context,
                                                                  ).push(
                                                                    MaterialPageRoute<
                                                                      void
                                                                    >(
                                                                      builder: (context) => _ExpenseDetailPage(
                                                                        householdId:
                                                                            householdIdStr,
                                                                        expenseId:
                                                                            d.id,
                                                                        uid: user
                                                                            .uid,
                                                                        title:
                                                                            title,
                                                                        amountCents:
                                                                            amountCents,
                                                                        paidByName:
                                                                            who,
                                                                        createdAt:
                                                                            createdAtDateTime,
                                                                        isPending:
                                                                            isPending,
                                                                        onManageNote:
                                                                            openNoteFlow,
                                                                      ),
                                                                    ),
                                                                  );
                                                                },
                                                                title: Text(
                                                                  title,
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                                subtitle:
                                                                    (noteSnap
                                                                            .hasError ||
                                                                        !noteSnap
                                                                            .hasData)
                                                                    ? Text(
                                                                        subtitleText,
                                                                        maxLines:
                                                                            1,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
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
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  mainAxisAlignment:
                                                                      MainAxisAlignment
                                                                          .end,
                                                                  children: [
                                                                    if (isPending)
                                                                      Tooltip(
                                                                        message:
                                                                            'Nog niet gesynchroniseerd',
                                                                        child: Icon(
                                                                          Icons
                                                                              .cloud_off,
                                                                          size:
                                                                              16,
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
                                                                      style: Theme.of(context)
                                                                          .textTheme
                                                                          .bodyMedium
                                                                          ?.copyWith(
                                                                            fontWeight:
                                                                                FontWeight.w700,
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

class _ExpenseDetailPage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
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
                  subtitle: Text(title),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bedrag'),
                  subtitle: Text(_formatEur(amountCents)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Betaald door'),
                  subtitle: Text(paidByName),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Datum/tijd'),
                  subtitle: Text(_formatDateTime(createdAt)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Status'),
                  subtitle: isPending
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
                        'households/$householdId/expenses/$expenseId/privateNotes/$uid',
                      )
                      .snapshots(includeMetadataChanges: true),
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
                        if (onManageNote != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: FilledButton.icon(
                              onPressed: () async => await onManageNote!(),
                              icon: Icon(
                                hasNoteLive
                                    ? Icons.edit_note
                                    : Icons.note_add_outlined,
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
    );
  }
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
                        onChanged: (_) => setState(() => _joinInlineHint = null),
                        decoration: const InputDecoration(
                          labelText: 'Koppelcode',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_joinInlineHint != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _joinInlineHint!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
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
    return PopScope(
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
