import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:sign_in_button/sign_in_button.dart';

import 'firebase_options.dart';

// ------------------------------------------------------------
// Color/alpha helpers (single-file)
// ------------------------------------------------------------
// Common semantic opacities used across the UI.
const double a06 = 0.06;
const double a32 = 0.32;
const double a40 = 0.40;
const double a45 = 0.45;
const double a50 = 0.50;
const double a55 = 0.55;
const double a58 = 0.58;
const double a60 = 0.60;
const double a62 = 0.62;
const double a68 = 0.68;
const double a70 = 0.70;
const double a84 = 0.84;
const double a85 = 0.85;

/// Product UI limit for expense titles; stays below the Firestore rules cap.
const int _kAddExpenseTitleMaxLength = 60;

/// Calm green for success overlays (e.g. join/connect confirmation).
const Color _kSuccessGreen = Color(0xFF2E7D32);

/// Lightweight value-object used by the "Voor wie?" feature.
class _ChildItem {
  const _ChildItem({required this.id, required this.name});
  final String id;
  final String name;
}

class _DashboardSecondaryMetadata {
  const _DashboardSecondaryMetadata({
    required this.otherName,
    required this.notesByExpenseId,
  });

  final String otherName;
  final Map<String, String> notesByExpenseId;
}

class _CreatedExpenseResult {
  const _CreatedExpenseResult({
    required this.expenseId,
    this.noteForRowFallback,
    this.successSnackBarMessage,
  });

  final String expenseId;
  final String? noteForRowFallback;
  final String? successSnackBarMessage;
}

class _PendingExpenseRowFallback {
  const _PendingExpenseRowFallback({
    required this.expenseId,
    required this.savedAt,
    this.note,
  });

  final String expenseId;
  final DateTime savedAt;
  final String? note;
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
                          autofocus: true,
                          maxLength: 180,
                          minLines: 3,
                          maxLines: 8,
                          textCapitalization: TextCapitalization.sentences,
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

// ── Shared private-note helpers (used by Dashboard and Logboek) ──────────────

/// Returns true when there is a live server connection for writing.
Future<bool> _checkCanWriteNow() async {
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

/// Shows the private-note edit dialog and returns a typed result.
/// Pure UI only – no Firestore.
Future<PrivateNoteDialogResult> _showPrivateNoteDialog(
  BuildContext context, {
  required String initialNote,
  required bool hasInitialNote,
}) async {
  final result = await showDialog<PrivateNoteDialogResult>(
    context: context,
    useRootNavigator: false,
    useSafeArea: true,
    barrierDismissible: false,
    builder: (dialogContext) => Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final keyboardVisible =
                    MediaQuery.of(dialogContext).viewInsets.bottom > 0;
                if (keyboardVisible) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  return;
                }
                Navigator.of(dialogContext, rootNavigator: false).pop();
              },
              child: const SizedBox.expand(),
            ),
          ),
          _PrivateNoteDialogContent(
            initialNote: initialNote,
            hasInitialNote: hasInitialNote,
          ),
        ],
      ),
    ),
  );
  return result ?? PrivateNoteDialogCancelled();
}

/// Shared note-management flow used by both Dashboard and Logboek.
///
/// Loads the latest note from Firestore, opens the edit dialog, verifies
/// connectivity before writing, persists to Firestore, and shows a snackbar.
/// Returns the committed [PrivateNoteDialogResult] so callers can bust local
/// caches; returns null on cancel, offline block, or error.
Future<PrivateNoteDialogResult?> _doManagePrivateNote(
  BuildContext context, {
  required String householdId,
  required String expenseId,
  required String uid,
}) async {
  try {
    final snap = await FirebaseFirestore.instance
        .doc('households/$householdId/expenses/$expenseId/privateNotes/$uid')
        .get();
    final initialNote = ((snap.data()?['note'] as String?) ?? '').trim();

    if (!context.mounted) return null;
    final result = await _showPrivateNoteDialog(
      context,
      initialNote: initialNote,
      hasInitialNote: initialNote.isNotEmpty,
    );

    if (result is PrivateNoteDialogCancelled) return null;
    if (!context.mounted) return null;

    if (!await _checkCanWriteNow()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Je bent offline. Notitie is niet gewijzigd. Verbind met internet en probeer opnieuw.',
              ),
            ),
          );
      }
      return null;
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

    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result is PrivateNoteDialogDelete
                  ? 'Notitie verwijderd.'
                  : 'Notitie opgeslagen.',
            ),
          ),
        );
    }
    return result;
  } catch (e) {
    debugPrint('Note save error: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              mapUserFacingError(
                e,
                fallback: 'Opslaan mislukt. Probeer opnieuw.',
              ),
            ),
          ),
        );
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

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
        final existingUser = FirebaseAuth.instance.currentUser;
        final shouldStartColdStartHandoff =
            snapshot.connectionState == ConnectionState.waiting &&
            existingUser != null &&
            _lastUid == null &&
            !_PostSignInHandoffController.isActive;
        if (shouldStartColdStartHandoff) {
          _PostSignInHandoffController.startWhiteHold();
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (_PostSignInHandoffController.isActive) {
            return _PostSignInHandoffController.loadingWidget;
          }
          return const _AuthGateBrandedLoading();
        }

        final user = snapshot.data;
        final currentUid = user?.uid;
        if (currentUid != _lastUid) {
          debugPrint('AuthGate authState change: uid=$_lastUid -> $currentUid');
          _lastUid = currentUid;
        }
        if (user == null) {
          _PostSignInHandoffController.clear();
          return const LoginPage();
        }

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          key: ValueKey('profileNameCheck-${user.uid}'),
          future: FirebaseFirestore.instance.doc('users/${user.uid}').get(),
          builder: (context, userDocSnapshot) {
            final dashboard = DashboardPage(
              key: ValueKey('dashboard-${user.uid}'),
              initialUserSnapshot: userDocSnapshot.data,
              onPreviewReadyChanged:
                  _PostSignInHandoffController.setDashboardReady,
            );

            if (userDocSnapshot.connectionState == ConnectionState.waiting) {
              if (_PostSignInHandoffController.isActive) {
                return _PostSignInHandoffGate(child: dashboard);
              }
              return const _AuthGateBrandedLoading();
            }

            if (userDocSnapshot.hasError) {
              _PostSignInHandoffController.clear();
              return const ProfileNamePage();
            }

            final data = userDocSnapshot.data?.data();
            final profileName = (data?['profileName'] as String?)?.trim();
            if (profileName == null || profileName.isEmpty) {
              _PostSignInHandoffController.clear();
              return const ProfileNamePage();
            }

            if (_PostSignInHandoffController.isActive) {
              return _PostSignInHandoffGate(child: dashboard);
            }
            return dashboard;
          },
        );
      },
    );
  }
}

class _PostSignInHandoffController {
  static const Duration minDuration = Duration(milliseconds: 1100);
  static const Duration brandedFadeDuration = Duration(milliseconds: 220);
  static const Duration whiteHoldFadeDuration = Duration(milliseconds: 350);
  static final ValueNotifier<bool> dashboardReady = ValueNotifier(false);
  static DateTime? _startedAt;
  static _PostSignInHandoffVisual _visual = _PostSignInHandoffVisual.branded;

  static bool get isActive => _startedAt != null;

  static void start() {
    _visual = _PostSignInHandoffVisual.branded;
    _startedAt = DateTime.now();
    dashboardReady.value = false;
  }

  static void startWhiteHold() {
    _visual = _PostSignInHandoffVisual.whiteHold;
    _startedAt = DateTime.now();
    dashboardReady.value = false;
  }

  static Duration get remaining {
    final startedAt = _startedAt;
    if (startedAt == null) {
      return Duration.zero;
    }
    if (_visual == _PostSignInHandoffVisual.whiteHold) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = minDuration - elapsed;
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
  }

  static void setDashboardReady(bool ready) {
    if (!isActive || dashboardReady.value == ready) {
      return;
    }
    dashboardReady.value = ready;
  }

  static Duration get fadeDuration => switch (_visual) {
    _PostSignInHandoffVisual.branded => brandedFadeDuration,
    _PostSignInHandoffVisual.whiteHold => whiteHoldFadeDuration,
  };

  static Widget get loadingWidget => switch (_visual) {
    _PostSignInHandoffVisual.branded => const _AuthGateBrandedLoading(),
    _PostSignInHandoffVisual.whiteHold => const _AuthGateWhiteHoldScreen(),
  };

  static void clear() {
    _startedAt = null;
    dashboardReady.value = false;
    _visual = _PostSignInHandoffVisual.branded;
  }
}

enum _PostSignInHandoffVisual { branded, whiteHold }

class _PostSignInHandoffGate extends StatefulWidget {
  const _PostSignInHandoffGate({required this.child});

  final Widget child;

  @override
  State<_PostSignInHandoffGate> createState() => _PostSignInHandoffGateState();
}

class _PostSignInHandoffGateState extends State<_PostSignInHandoffGate> {
  Timer? _minTimer;
  bool _minElapsed = false;
  bool _revealed = false;
  late final Duration _fadeDuration;
  late final Widget _loadingWidget;

  @override
  void initState() {
    super.initState();
    _fadeDuration = _PostSignInHandoffController.fadeDuration;
    _loadingWidget = _PostSignInHandoffController.loadingWidget;
    _PostSignInHandoffController.dashboardReady.addListener(_maybeReveal);
    final remaining = _PostSignInHandoffController.remaining;
    if (remaining == Duration.zero) {
      _minElapsed = true;
    } else {
      _minTimer = Timer(remaining, () {
        if (!mounted) {
          return;
        }
        _minElapsed = true;
        _maybeReveal();
      });
    }
    _maybeReveal();
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _PostSignInHandoffController.dashboardReady.removeListener(_maybeReveal);
    super.dispose();
  }

  void _maybeReveal() {
    if (!mounted ||
        _revealed ||
        !_minElapsed ||
        !_PostSignInHandoffController.dashboardReady.value) {
      return;
    }
    _PostSignInHandoffController.clear();
    setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: !_revealed,
          child: AnimatedOpacity(
            opacity: _revealed ? 1 : 0,
            duration: _fadeDuration,
            curve: Curves.easeOut,
            child: widget.child,
          ),
        ),
        IgnorePointer(
          ignoring: _revealed,
          child: AnimatedOpacity(
            opacity: _revealed ? 0 : 1,
            duration: _fadeDuration,
            curve: Curves.easeOut,
            child: _loadingWidget,
          ),
        ),
      ],
    );
  }
}

class _AuthGateBrandedLoading extends StatelessWidget {
  const _AuthGateBrandedLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF7F6F4),
      body: Align(
        alignment: Alignment(0, 0.0),
        child: Image(
          image: AssetImage('assets/images/kidu_icon.png'),
          width: 72,
        ),
      ),
    );
  }
}

class _AuthGateWhiteHoldScreen extends StatelessWidget {
  const _AuthGateWhiteHoldScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.white);
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
  final FocusNode _nameFocus = FocusNode();
  bool _busy = false;
  String? _nameInlineHint;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialName;
    if (initial != null && initial.trim().isNotEmpty) {
      _controller.text = initial.trim();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _nameFocus.requestFocus();
      }
    });
  }

  void _showSnackBar(String message, {Duration? duration}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(content: Text(message), duration: duration ?? const Duration(seconds: 4)),
    );
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
        final userSnap = await FirebaseFirestore.instance
            .doc('users/$uid')
            .get();
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardPage(initialUserSnapshot: userSnap),
          ),
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
    _nameFocus.dispose();
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
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 20,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: KiduCard(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Welke naam wil je gebruiken?',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              height: 1.25,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Deze naam is zichtbaar in jullie gedeelde KiDu-overzicht.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: onSurface(context, a68),
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Container(
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(
                            Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: a06),
                            Theme.of(context).colorScheme.surface,
                          ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: outlineV(context, a45)),
                        ),
                        child: TextField(
                          controller: _controller,
                          focusNode: _nameFocus,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: 20,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _busy ? null : _save(),
                          onChanged: (_) {
                            if (_nameInlineHint != null) {
                              setState(() => _nameInlineHint = null);
                            }
                          },
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.12,
                              ),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            counterText: '',
                          ),
                        ),
                      ),
                      if (_nameInlineHint != null) ...[
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            _nameInlineHint!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: onSurface(context, a62),
                                  height: 1.35,
                                ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _save,
                        icon: _busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            : const Icon(Icons.check, size: 18),
                        label: Text(
                          'Opslaan',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
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

  void _showSnackBar(String message, {Duration? duration}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
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
      _PostSignInHandoffController.start();
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
    if (_PostSignInHandoffController.isActive) {
      return const _AuthGateBrandedLoading();
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(top: 34, bottom: 38),
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
  const DashboardPage({
    super.key,
    this.initialUserSnapshot,
    this.onPreviewReadyChanged,
  });

  /// Seeds the user-doc stream from [AuthGate] to skip an extra loading frame.
  final DocumentSnapshot<Map<String, dynamic>>? initialUserSnapshot;
  final ValueChanged<bool>? onPreviewReadyChanged;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _setupBusy = false;
  bool _inviteBusy = false;
  bool _inviteSheetOpening = false;
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
  String? _dashboardSecondaryMetadataCacheKey;
  Future<_DashboardSecondaryMetadata>? _dashboardSecondaryMetadataFuture;
  String? _lastVisibleDashboardSecondaryMetadataScopeKey;
  _DashboardSecondaryMetadata? _lastVisibleDashboardSecondaryMetadata;
  _PendingExpenseRowFallback? _pendingExpenseRowFallback;

  List<_ChildItem> _dashChildren = [];
  String? _dashChildrenHouseholdId;

  String? _settlementsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _settlementsSubscription;
  int _totalPaidByMe = 0;
  int _totalPaidToMe = 0;

  String? _paymentsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _paymentsSubscription;
  Map<String, dynamic>? _pendingIncoming;
  String? _pendingIncomingId;
  Map<String, dynamic>? _pendingOutgoing;

  String? _confirmedPaymentsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _confirmedPaymentsSubscription;
  int _confirmedPaidByMe = 0;
  int _confirmedPaidToMe = 0;
  bool? _lastReportedPreviewReady;

  void _reportPreviewReady(bool ready) {
    if (_lastReportedPreviewReady == ready) {
      return;
    }
    _lastReportedPreviewReady = ready;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onPreviewReadyChanged?.call(ready);
    });
  }

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

  Future<String> _loadUserDisplayName({
    required String uid,
    required String fallback,
  }) async {
    try {
      final snap = await FirebaseFirestore.instance.doc('users/$uid').get();
      final data = snap.data();
      final profileName = (data?['profileName'] as String?)?.trim();
      final displayName = (data?['displayName'] as String?)?.trim();
      final email = (data?['email'] as String?)?.trim();

      return (profileName != null && profileName.isNotEmpty)
          ? profileName
          : (displayName != null && displayName.isNotEmpty)
          ? displayName
          : (email != null && email.isNotEmpty)
          ? email
          : fallback;
    } catch (e) {
      debugPrint('Fetch user name error (uid=$uid): $e');
      return fallback;
    }
  }

  Future<_DashboardSecondaryMetadata> _fetchDashboardSecondaryMetadata({
    required String householdId,
    required String otherUid,
    required List<String> visibleOwnExpenseIds,
    required String otherFallback,
  }) async {
    final otherNameFuture = _loadUserDisplayName(
      uid: otherUid,
      fallback: otherFallback,
    );
    final notesFuture = Future.wait(
      visibleOwnExpenseIds.map(
        (expenseId) => _getNoteFuture(
          householdId,
          expenseId,
        ).then((note) => MapEntry(expenseId, note)),
      ),
    );

    final otherName = await otherNameFuture;
    final noteEntries = await notesFuture;
    final notesByExpenseId = <String, String>{};
    for (final entry in noteEntries) {
      final note = entry.value?.trim();
      if (note != null && note.isNotEmpty) {
        notesByExpenseId[entry.key] = note;
      }
    }

    return _DashboardSecondaryMetadata(
      otherName: otherName,
      notesByExpenseId: notesByExpenseId,
    );
  }

  Future<_DashboardSecondaryMetadata> _getDashboardSecondaryMetadataFuture({
    required String householdId,
    required String otherUid,
    required List<String> visibleOwnExpenseIds,
  }) {
    final visibleIdsKey = visibleOwnExpenseIds.join(',');
    final key = '$householdId|$otherUid|$visibleIdsKey|$_notesRefreshTick';
    if (_dashboardSecondaryMetadataFuture == null ||
        _dashboardSecondaryMetadataCacheKey != key) {
      _dashboardSecondaryMetadataCacheKey = key;
      _dashboardSecondaryMetadataFuture = _fetchDashboardSecondaryMetadata(
        householdId: householdId,
        otherUid: otherUid,
        visibleOwnExpenseIds: visibleOwnExpenseIds,
        otherFallback: 'Co-parent',
      );
    }
    return _dashboardSecondaryMetadataFuture!;
  }

  String _formatDashboardExpenseDate(DateTime? dt) {
    if (dt == null) return '';
    const nlMonths = <String>[
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
    return '${dt.day} ${nlMonths[dt.month - 1]}';
  }

  static const double _pagePadding = 16;
  static const double _cardRadius = 18;
  static const double _cardGap = 16;

  void _showSnackBar(String message, {Duration? duration}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  /// Thin dashboard wrapper around [_doManagePrivateNote].
  /// Guards against concurrent taps and busts the local note-cache on success.
  Future<void> _openEditPrivateNoteDialog({
    required String householdId,
    required String expenseId,
    required String uid,
  }) async {
    if (_noteWriteInFlight) return;
    _noteWriteInFlight = true;
    try {
      final result = await _doManagePrivateNote(
        context,
        householdId: householdId,
        expenseId: expenseId,
        uid: uid,
      );
      if (result != null && mounted) {
        setState(() {
          _notesRefreshTick++;
          _noteFutureCache.clear();
        });
      }
    } finally {
      _noteWriteInFlight = false;
    }
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
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    // Dutch thousands separator '.' and decimal separator ','.
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
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
      result[uid] = await _loadUserDisplayName(uid: uid, fallback: fallback);
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

  void _startSettlementsSubscription(String householdId, String myUid) {
    if (_settlementsHouseholdId == householdId) return;
    _settlementsSubscription?.cancel();
    _settlementsHouseholdId = householdId;
    _settlementsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/settlements')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          var paidByMe = 0;
          var paidToMe = 0;
          for (final doc in snap.docs) {
            final d = doc.data();
            final cents = (d['amountCents'] as num?)?.toInt() ?? 0;
            final debtor = (d['debtorUid'] as String?)?.trim();
            final creditor = (d['creditorUid'] as String?)?.trim();
            if (debtor == myUid) paidByMe += cents;
            if (creditor == myUid) paidToMe += cents;
          }
          setState(() {
            _totalPaidByMe = paidByMe;
            _totalPaidToMe = paidToMe;
          });
        });
  }

  void _startPaymentsSubscription(String householdId, String myUid) {
    if (_paymentsHouseholdId == householdId) return;
    _paymentsSubscription?.cancel();
    _paymentsHouseholdId = householdId;
    _paymentsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/payments')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          Map<String, dynamic>? incoming;
          String? incomingId;
          Map<String, dynamic>? outgoing;
          for (final doc in snap.docs) {
            final d = doc.data();
            final to = (d['toUserId'] as String?)?.trim();
            final from = (d['fromUserId'] as String?)?.trim();
            if (to == myUid && incoming == null) {
              incoming = d;
              incomingId = doc.id;
            }
            if (from == myUid && outgoing == null) {
              outgoing = d;
            }
          }
          setState(() {
            _pendingIncoming = incoming;
            _pendingIncomingId = incomingId;
            _pendingOutgoing = outgoing;
          });
        });
  }

  void _startConfirmedPaymentsSubscription(String householdId, String myUid) {
    if (_confirmedPaymentsHouseholdId == householdId) return;
    _confirmedPaymentsSubscription?.cancel();
    _confirmedPaymentsHouseholdId = householdId;
    _confirmedPaymentsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/payments')
        .where('status', isEqualTo: 'confirmed')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          var paidByMe = 0;
          var paidToMe = 0;
          for (final doc in snap.docs) {
            final d = doc.data();
            final cents = (d['amountCents'] as num?)?.toInt() ?? 0;
            final from = (d['fromUserId'] as String?)?.trim();
            final to = (d['toUserId'] as String?)?.trim();
            if (from == myUid) paidByMe += cents;
            if (to == myUid) paidToMe += cents;
          }
          setState(() {
            _confirmedPaidByMe = paidByMe;
            _confirmedPaidToMe = paidToMe;
          });
        });
  }

  Future<void> _loadDashChildrenOnce(String householdId) async {
    if (householdId.isEmpty) return;
    if (_dashChildrenHouseholdId == householdId && _dashChildren.isNotEmpty) {
      return;
    }
    final kids = await _loadActiveChildren(householdId);
    if (!mounted) return;
    setState(() {
      _dashChildren = kids;
      _dashChildrenHouseholdId = householdId;
    });
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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
                  child: KiduCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isPaired ? 'Instellingen' : 'Koppel met co-parent',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        if (isPaired)
                          Text(
                            trimmedOther == 'Co-parent'
                                ? 'Je bent nog niet gekoppeld'
                                : 'Verbonden met $effectiveOtherName',
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
                        const SizedBox(height: 16),
                        if (!isPaired && hasHousehold && canInvite) ...[
                          FilledButton.tonalIcon(
                            onPressed: _inviteBusy
                                ? null
                                : () async {
                                    HapticFeedback.selectionClick();
                                    await _generateInvite(householdId);
                                    if (context.mounted) {
                                      setModalState(() {});
                                    }
                                  },
                            icon: Icon(
                              Icons.key_outlined,
                              size: 18,
                              color: onSurface(context, a58),
                            ),
                            label: Text(
                              _inviteBusy ? 'Bezig...' : 'Genereer invite code',
                              style: Theme.of(context).textTheme.bodyMedium,
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
                            FilledButton.tonalIcon(
                              onPressed: () => _shareInviteCode(_inviteCode!),
                              icon: const Icon(Icons.share_outlined, size: 18),
                              label: Text(
                                'Delen',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                          const SizedBox(height: _cardGap),
                        ],
                        if (!isPaired) ...[
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.of(rootContext).push(
                                MaterialPageRoute(
                                  builder: (_) => const SetupPage(),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.link,
                              size: 18,
                              color: onSurface(context, a70),
                            ),
                            label: Text(
                              'Ik heb een invite-code',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: onSurface(context, a70)),
                            ),
                          ),
                        ],
                        Divider(height: 24, color: outlineV(context, a40)),
                        Text(
                          'Account',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: onSurface(context, a70),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Naam',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
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
                        const SizedBox(height: 16),
                        Text(
                          'Huishouden',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: onSurface(context, a70),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        if (hasHousehold)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            visualDensity: VisualDensity.standard,
                            leading: Icon(
                              Icons.child_care_outlined,
                              size: 18,
                              color: onSurface(context, a50),
                            ),
                            title: Text(
                              'Kinderen',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: onSurface(context, a70)),
                            ),
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
                            visualDensity: VisualDensity.standard,
                            leading: Icon(
                              Icons.menu_book_outlined,
                              size: 18,
                              color: onSurface(context, a50),
                            ),
                            title: Text(
                              'Logboek',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: onSurface(context, a70)),
                            ),
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
                        const SizedBox(height: 16),
                        Text(
                          'Info',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: onSurface(context, a70),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.privacy_tip_outlined,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Privacy',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
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
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.info_outline,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Over KiDu',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
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
                        Divider(height: 32, color: outlineV(context, a40)),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.logout,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Uitloggen',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
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
              ),
            );
          },
        );
      },
    );
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

  Future<_CreatedExpenseResult?> _createExpense({
    required String householdId,
    required String title,
    required int amountCents,
    String? note,
    String? coparentNameForPendingMessage,
    List<String>? childIds,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return null;
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
      }
      return _CreatedExpenseResult(
        expenseId: ref.id,
        noteForRowFallback: noteErrMsg == null ? noteTrimmed : null,
        successSnackBarMessage: isPending
            ? null
            : (noteErrMsg != null
                  ? 'Uitgave opgeslagen, $noteErrMsg'
                  : 'Uitgave opgeslagen.'),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Create expense error: $e');
      rethrow;
    }
  }

  Future<List<String>?> _openAddExpenseChildSelectionDialog({
    required List<_ChildItem> children,
    List<String> initialSelectedChildIds = const [],
  }) async {
    final allChildIds = children.map((c) => c.id).toList(growable: false);
    return showDialog<List<String>>(
      context: context,
      useSafeArea: true,
      barrierDismissible: true,
      builder: (context) {
        var selectedChildIds = initialSelectedChildIds
            .where(allChildIds.contains)
            .toSet();
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final selectedCount = selectedChildIds.length;
            final allSelected = selectedCount == allChildIds.length;
            final cs = Theme.of(context).colorScheme;
            final dialogBackground = cs.surfaceContainerHigh;
            final screenW = MediaQuery.sizeOf(context).width;
            final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
            final modalHeight = min(
              520.0,
              MediaQuery.of(context).size.height - 36,
            );
            void dismissSelectionDialog() => Navigator.of(context).pop();
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 24,
              ),
              child: SafeArea(
                child: Align(
                  alignment: const Alignment(0, -0.08),
                  child: SizedBox(
                    width: dialogW,
                    child: SizedBox(
                      height: modalHeight,
                      child: Material(
                        color: dialogBackground,
                        elevation: 3,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.circular(
                          _DashboardPageState._cardRadius,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              _DashboardPageState._cardRadius,
                            ),
                            border: Border.all(color: outlineV(context, a40)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: cs.outlineVariant.withValues(
                                        alpha: 0.85,
                                      ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                                child: Text(
                                  'Selectie',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w400,
                                        color: onSurface(context, a84),
                                      ),
                                ),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      TextButton(
                                        onPressed: () => setLocalState(() {
                                          selectedChildIds = allSelected
                                              ? <String>{}
                                              : allChildIds.toSet();
                                        }),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: Text(
                                          allSelected
                                              ? 'Alles deselecteren'
                                              : 'Alles selecteren',
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        height: 28,
                                        child: Align(
                                          alignment: Alignment.topLeft,
                                          child: Opacity(
                                            opacity: selectedCount == 0 ? 1 : 0,
                                            child: Text(
                                              'Selecteer minimaal 1 kind om verder te gaan',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall?.copyWith(
                                                color: onSurface(context, a68),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: ListView.separated(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                            bottom: 4,
                                          ),
                                          itemCount: children.length,
                                          separatorBuilder: (_, _) => Divider(
                                            height: 1,
                                            thickness: 0.4,
                                            color: cs.outlineVariant.withValues(
                                              alpha: 0.45,
                                            ),
                                          ),
                                          itemBuilder: (context, index) {
                                            final child = children[index];
                                            final selected = selectedChildIds
                                                .contains(child.id);
                                            return Material(
                                              type: MaterialType.transparency,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                onTap: () {
                                                  setLocalState(() {
                                                    if (selected) {
                                                      selectedChildIds =
                                                          selectedChildIds
                                                              .where(
                                                                (id) =>
                                                                    id !=
                                                                    child.id,
                                                              )
                                                              .toSet();
                                                    } else {
                                                      selectedChildIds = {
                                                        ...selectedChildIds,
                                                        child.id,
                                                      };
                                                    }
                                                  });
                                                },
                                                child: ListTile(
                                                  dense: true,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  minLeadingWidth: 32,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 2,
                                                        vertical: 0,
                                                      ),
                                                  leading: Checkbox(
                                                    value: selected,
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    activeColor: cs.primary
                                                        .withValues(alpha: a84),
                                                    checkColor: cs.surface,
                                                    side: BorderSide(
                                                      color: cs.outlineVariant
                                                          .withValues(
                                                            alpha: 0.85,
                                                          ),
                                                    ),
                                                    onChanged: (value) {
                                                      setLocalState(() {
                                                        if (value ?? false) {
                                                          selectedChildIds = {
                                                            ...selectedChildIds,
                                                            child.id,
                                                          };
                                                        } else {
                                                          selectedChildIds =
                                                              selectedChildIds
                                                                  .where(
                                                                    (id) =>
                                                                        id !=
                                                                        child
                                                                            .id,
                                                                  )
                                                                  .toSet();
                                                        }
                                                      });
                                                    },
                                                  ),
                                                  title: Text(
                                                    child.name,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a84,
                                                          ),
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: dialogBackground,
                                  border: Border(
                                    top: BorderSide(
                                      color: outlineV(context, a32),
                                    ),
                                  ),
                                ),
                                child: SafeArea(
                                  top: false,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      12,
                                    ),
                                    child: Row(
                                      children: [
                                        TextButton(
                                          onPressed: dismissSelectionDialog,
                                          child: const Text('Annuleren'),
                                        ),
                                        const Spacer(),
                                        ElevatedButton(
                                          onPressed: selectedCount == 0
                                              ? null
                                              : () => Navigator.of(context).pop(
                                                  children
                                                      .where(
                                                        (child) =>
                                                            selectedChildIds
                                                                .contains(
                                                                  child.id,
                                                                ),
                                                      )
                                                      .map((child) => child.id)
                                                      .toList(),
                                                ),
                                          child: const Text('Gereed'),
                                        ),
                                      ],
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
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openAddExpenseDialog(
    String householdId, {
    String? coparentName,
    List<_ChildItem> children = const [],
  }) async {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final titleFocusNode = FocusNode();
    final amountFocusNode = FocusNode();
    final allChildIds = children.map((c) => c.id).toList(growable: false);
    var saving = false;
    var didShow = false;
    String? pendingSuccessSnackBarMessage;
    var hasCustomChildSelection = false;
    var customSelectedChildIds = <String>[];
    var titleHasError = false;
    var amountHasError = false;
    _freezeExpensesVN.value = true;

    try {
      didShow = true;
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              final effectiveSelectedChildIds = hasCustomChildSelection
                  ? customSelectedChildIds
                  : allChildIds;
              final screenW = MediaQuery.sizeOf(context).width;
              final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
              final subtleErrorHintStyle = Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  );
              final subtleErrorInputStyle = Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.88),
                    fontWeight: FontWeight.w400,
                  );
              final childSelectionSummary =
                  !hasCustomChildSelection ||
                      effectiveSelectedChildIds.length == children.length
                  ? 'Alle kinderen'
                  : '${effectiveSelectedChildIds.length} van ${children.length} geselecteerd';
              return Material(
                color: Colors.transparent,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final keyboardVisible =
                              MediaQuery.of(context).viewInsets.bottom > 0;
                          if (keyboardVisible) {
                            FocusManager.instance.primaryFocus?.unfocus();
                            return;
                          }
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Align(
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
                              focusNode: titleFocusNode,
                              autofocus: true,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.next,
                              maxLength: _kAddExpenseTitleMaxLength,
                              onTap: () {
                                if (titleHasError) {
                                  setLocalState(() => titleHasError = false);
                                }
                              },
                              onChanged: (_) {
                                if (titleHasError) {
                                  setLocalState(() => titleHasError = false);
                                }
                              },
                              buildCounter:
                                  (
                                    context, {
                                    required int currentLength,
                                    required bool isFocused,
                                    required int? maxLength,
                                  }) => null,
                              decoration: InputDecoration(
                                labelText: 'Titel',
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                                border: OutlineInputBorder(),
                                hintText: titleHasError ? 'Vul een titel in' : null,
                                hintStyle: titleHasError
                                    ? subtleErrorHintStyle
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: amountController,
                              focusNode: amountFocusNode,
                              style: amountHasError
                                  ? subtleErrorInputStyle
                                  : null,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onTap: () {
                                if (amountHasError) {
                                  setLocalState(() => amountHasError = false);
                                }
                              },
                              onChanged: (value) {
                                final trimmed = value.trim();
                                final parsed = _tryParseEurToCents(value);
                                final nextHasError =
                                    trimmed.isNotEmpty &&
                                    (parsed == null || parsed <= 0);
                                if (amountHasError != nextHasError) {
                                  setLocalState(
                                    () => amountHasError = nextHasError,
                                  );
                                }
                              },
                              decoration: InputDecoration(
                                labelText: 'Bedrag (EUR)',
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                                border: OutlineInputBorder(),
                                hintText: amountHasError
                                    ? 'Vul een geldig bedrag in'
                                    : 'Bijv. 12,34',
                                hintStyle: amountHasError
                                    ? subtleErrorHintStyle
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: noteController,
                              textCapitalization: TextCapitalization.sentences,
                              maxLength: 180,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(
                                labelText: 'Notitie (optioneel)',
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                                border: OutlineInputBorder(),
                              ),
                            ),
                            // Child selection stays out of the main dialog for
                            // 2+ children so the form remains compact.
                            if (children.length > 1) ...[
                              const SizedBox(height: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Voor:',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          childSelectionSummary,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: saving
                                            ? null
                                            : () async {
                                                FocusManager.instance.primaryFocus
                                                    ?.unfocus();
                                                final pickedChildIds =
                                                    await _openAddExpenseChildSelectionDialog(
                                                      children: children,
                                                      initialSelectedChildIds:
                                                          hasCustomChildSelection
                                                          ? customSelectedChildIds
                                                          : const <String>[],
                                                    );
                                                if (pickedChildIds == null ||
                                                    !context.mounted) {
                                                  return;
                                                }
                                                setLocalState(() {
                                                  if (pickedChildIds.length ==
                                                      children.length) {
                                                    hasCustomChildSelection =
                                                        false;
                                                    customSelectedChildIds = [];
                                                  } else {
                                                    hasCustomChildSelection =
                                                        true;
                                                    customSelectedChildIds =
                                                        pickedChildIds;
                                                  }
                                                });
                                              },
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('Selectie'),
                                      ),
                                    ],
                                  ),
                                ],
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
                                final titleInvalid = title.isEmpty;
                                final amountInvalid =
                                    amountCents == null || amountCents <= 0;
                                if (titleInvalid || amountInvalid) {
                                  setLocalState(() {
                                    titleHasError = titleInvalid;
                                    amountHasError = amountInvalid;
                                  });
                                  if (titleInvalid) {
                                    titleFocusNode.requestFocus();
                                  } else if (amountInvalid) {
                                    amountFocusNode.requestFocus();
                                  }
                                  return;
                                }
                                if (effectiveSelectedChildIds.isEmpty) {
                                  _showSnackBar('Selecteer minimaal één kind.');
                                  return;
                                }

                                setLocalState(() => saving = true);
                                if (!await _checkCanWriteNow()) {
                                  _showSnackBar(
                                    'Je bent offline. Uitgave niet opgeslagen. Verbind met internet en probeer opnieuw.',
                                  );
                                  if (context.mounted) {
                                    setLocalState(() => saving = false);
                                  }
                                  return;
                                }
                                try {
                                  final savedAt = DateTime.now();
                                  final createResult = await _createExpense(
                                    householdId: householdId,
                                    title: title,
                                    amountCents: amountCents,
                                    note: noteController.text.trim().isEmpty
                                        ? null
                                        : noteController.text.trim(),
                                    coparentNameForPendingMessage: coparentName,
                                    childIds: effectiveSelectedChildIds,
                                  );
                                  if (mounted && createResult != null) {
                                    setState(() {
                                      _pendingExpenseRowFallback =
                                          _PendingExpenseRowFallback(
                                            expenseId: createResult.expenseId,
                                            savedAt: savedAt,
                                            note:
                                                createResult.noteForRowFallback,
                                          );
                                    });
                                    pendingSuccessSnackBarMessage =
                                        createResult.successSnackBarMessage;
                                  }
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
                    ),
                  ],
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
      if (mounted) {
        _freezeExpensesVN.value = false;
        if (pendingSuccessSnackBarMessage != null) {
          await WidgetsBinding.instance.endOfFrame;
          if (mounted) {
            _showSnackBar(
              pendingSuccessSnackBarMessage!,
              duration: const Duration(milliseconds: 2200),
            );
          }
        }
      }
      titleController.dispose();
      amountController.dispose();
      noteController.dispose();
      titleFocusNode.dispose();
      amountFocusNode.dispose();
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
    widget.onPreviewReadyChanged?.call(false);
    _settlementsSubscription?.cancel();
    _paymentsSubscription?.cancel();
    _confirmedPaymentsSubscription?.cancel();
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
    var waiting = false;
    String? code;
    String? error;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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

            Widget buildInviteCodeContent() {
              if (loading || code != null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Uitnodigingscode',
                      style: Theme.of(sheetContext).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    KiduCodePill(
                      code: code ?? '',
                      loading: loading,
                      codeFontWeight: FontWeight.w600,
                      onCopy: () async {
                        await Clipboard.setData(ClipboardData(text: code!));
                        _showSnackBar('Invite code gekopieerd.');
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        if (loading) return;
                        _shareInviteCode(code!);
                      },
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: Text(
                        'Delen',
                        style: Theme.of(sheetContext).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        if (loading) return;
                        setModalState(() => waiting = true);
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        'Code gedeeld',
                        style: Theme.of(sheetContext).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Uitnodigingscode',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error ?? 'Kon geen code maken. Probeer opnieuw.',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: onSurface(sheetContext, a68)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      setModalState(() {
                        started = false;
                        loading = true;
                        code = null;
                        error = null;
                      });
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      'Opnieuw',
                      style: Theme.of(sheetContext).textTheme.bodyMedium,
                    ),
                  ),
                ],
              );
            }

            Widget buildWaitingContent() {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Wachten op co-parent',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Je hebt de code gedeeld.\nZodra je co-parent koppelt, verschijnt het gedeelde overzicht automatisch.',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: onSurface(sheetContext, a68)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                    },
                    icon: const Icon(Icons.dashboard_outlined, size: 18),
                    label: Text(
                      'Terug naar dashboard',
                      style: Theme.of(sheetContext).textTheme.bodyMedium,
                    ),
                  ),
                ],
              );
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
                  child: KiduCard(
                    child: waiting
                        ? Stack(
                            children: [
                              IgnorePointer(
                                child: Visibility(
                                  visible: false,
                                  maintainState: true,
                                  maintainAnimation: true,
                                  maintainSize: true,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: buildInviteCodeContent(),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: buildWaitingContent(),
                              ),
                            ],
                          )
                        : buildInviteCodeContent(),
                  ),
                ),
              ),
            );
          },
        );
      },
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
      _reportPreviewReady(false);
      // Avoid endless spinner if auth state flips during navigation/sign-out.
      return const AuthGate();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.doc('users/${user.uid}').snapshots(),
      initialData: widget.initialUserSnapshot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _reportPreviewReady(true);
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
        // Do not treat ConnectionState.waiting as loading when [initialData] is
        // present — Firestore keeps waiting until the first snapshot event.
        if (!snapshot.hasData) {
          _reportPreviewReady(false);
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

        if (householdIdStr.isNotEmpty &&
            _dashChildrenHouseholdId != householdIdStr) {
          Future.microtask(() => _loadDashChildrenOnce(householdIdStr));
        }
        if (householdIdStr.isNotEmpty) {
          Future.microtask(
            () => _startSettlementsSubscription(householdIdStr, user.uid),
          );
          Future.microtask(
            () => _startPaymentsSubscription(householdIdStr, user.uid),
          );
          Future.microtask(
            () => _startConfirmedPaymentsSubscription(householdIdStr, user.uid),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>?>(
          stream: hasHousehold
              ? FirebaseFirestore.instance
                    .collection('households/$householdIdStr/members')
                    .limit(2)
                    .snapshots()
              : Stream.value(null),
          builder: (context, membersSnapshot) {
            // Avoid full-screen loading here: while members are resolving, keep
            // the normal dashboard subtree (invite flow) instead of replacing the
            // scaffold with a spinner (jank when household first appears).
            if (hasHousehold && membersSnapshot.hasError) {
              _reportPreviewReady(true);
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

            final membersAwaitingFirstSnapshot =
                hasHousehold &&
                !membersSnapshot.hasData &&
                !membersSnapshot.hasError;

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

            final canInvite = membersAwaitingFirstSnapshot || memberCount == 1;
            final canAddExpenses =
                otherUid != null && otherUid.trim().isNotEmpty;
            final showsPendingSoloPreview =
                !canAddExpenses && membersAwaitingFirstSnapshot;
            final showsStableSoloDashboard =
                !canAddExpenses && !membersAwaitingFirstSnapshot;
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

            // While the first members snapshot is pending, keep the same ungekoppeld
            // subtree as when docs=1 (avoids a full-screen spinner flash when
            // householdId first appears, e.g. behind the invite bottom sheet).

            if (showsPendingSoloPreview || showsStableSoloDashboard) {
              _reportPreviewReady(showsStableSoloDashboard);
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
                                                    label:
                                                        'Totaal samen uitgegeven',
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
                                                      a40,
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
                                                    'Recente uitgaven',
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
                                                        onPressed:
                                                            (_inviteBusy ||
                                                                _setupBusy)
                                                            ? null
                                                            : () async {
                                                                if (_inviteSheetOpening) {
                                                                  return;
                                                                }
                                                                HapticFeedback.selectionClick();
                                                                _inviteSheetOpening =
                                                                    true;
                                                                try {
                                                                  await _openInviteSheetFlow(
                                                                    householdIdStr,
                                                                  );
                                                                } finally {
                                                                  if (mounted) {
                                                                    _inviteSheetOpening =
                                                                        false;
                                                                  }
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
                  floatingActionButtonLocation:
                      FloatingActionButtonLocation.centerFloat,
                  floatingActionButton: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width - 48,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'logboek_fab',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _LogboekPage(
                                  householdId: householdIdStr,
                                  uid: user.uid,
                                  myName: myName,
                                  otherName: otherName,
                                ),
                              ),
                            ),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            elevation: 3,
                            tooltip: 'Logboek',
                            child: const Icon(Icons.menu_book, size: 20),
                          ),
                          if (canAddExpenses)
                            ValueListenableBuilder<bool>(
                              valueListenable: _addExpenseDialogOpenVN,
                              builder: (context, dialogOpen, _) {
                                return ValueListenableBuilder<bool>(
                                  valueListenable: _addExpenseCheckBusyVN,
                                  builder: (context, fabBusy, _) {
                                    final bool addExpenseBusy =
                                        dialogOpen ||
                                        fabBusy ||
                                        _setupBusy ||
                                        _inviteBusy;

                                    return FloatingActionButton(
                                      heroTag: 'add_expense_fab',
                                      onPressed: addExpenseBusy
                                          ? null
                                          : () async {
                                              if (_addExpenseCheckBusyVN
                                                      .value ||
                                                  _addExpenseDialogOpenVN
                                                      .value) {
                                                return;
                                              }
                                              // Capture before any awaits so the
                                              // local builder context isn't used
                                              // across async gaps.
                                              final messenger =
                                                  ScaffoldMessenger.of(context);
                                              final nav = Navigator.of(context);
                                              _addExpenseCheckBusyVN.value =
                                                  true;
                                              var didOpenDialog = false;
                                              try {
                                                if (!await _checkCanWriteNow()) {
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
                                                  messenger
                                                      .hideCurrentSnackBar();
                                                  messenger.showSnackBar(
                                                    SnackBar(
                                                      content: const Text(
                                                        'Voeg eerst een kind toe om een uitgave te registreren.',
                                                      ),
                                                      action: SnackBarAction(
                                                        label: 'Kinderen',
                                                        onPressed: () => nav.push(
                                                          MaterialPageRoute<
                                                            void
                                                          >(
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
                                      child: const Icon(Icons.add, size: 24),
                                    );
                                  },
                                );
                              },
                            )
                          else
                            const SizedBox(width: 40, height: 40),
                        ],
                      ),
                    ),
                  ),
                  body: MediaQuery.removeViewInsets(
                    context: context,
                    removeBottom: true,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _pagePadding,
                          24,
                          _pagePadding,
                          80,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: min(constraints.maxWidth, 520.0),
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
                                          _reportPreviewReady(true);
                                          return const Text(
                                            'Kon uitgaven niet laden.',
                                          );
                                        }
                                        if (effectiveSnap == null) {
                                          _reportPreviewReady(false);
                                          return const Center(
                                            child: CircularProgressIndicator(),
                                          );
                                        }

                                        final docs = effectiveSnap.docs;
                                        final visibleDocs = docs.take(6).toList(
                                          growable: false,
                                        );
                                        final visibleOwnExpenseIds =
                                            visibleDocs
                                                .where(
                                                  (d) =>
                                                      ((d
                                                                  .data()['createdBy']
                                                              as String?)
                                                          ?.trim()) ==
                                                      user.uid,
                                                )
                                                .map((d) => d.id)
                                                .toList(growable: false);

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
                                        final rawBalanceCents =
                                            myPaidCents - expectedMy;
                                        final balanceCents =
                                            rawBalanceCents +
                                            _totalPaidByMe -
                                            _totalPaidToMe +
                                            _confirmedPaidByMe -
                                            _confirmedPaidToMe;

                                        final absBalance = balanceCents.abs();
                                        final pendingInCents =
                                            (_pendingIncoming?['amountCents']
                                                    as num?)
                                                ?.toInt();
                                        final pendingOutCents =
                                            (_pendingOutgoing?['amountCents']
                                                    as num?)
                                                ?.toInt();

                                        String? lastActivityText;
                                        if (docs.isNotEmpty) {
                                          final first = docs.first;
                                          final e = first.data();
                                          final createdAt =
                                              e['createdAt'] as Timestamp?;
                                          final timeStr = createdAt == null
                                              ? 'zojuist'
                                              : _formatRelativeNl(
                                                  createdAt.toDate(),
                                                );
                                          lastActivityText =
                                              'Laatste activiteit · $timeStr';
                                        }

                                        final secondaryMetadataFuture =
                                            _getDashboardSecondaryMetadataFuture(
                                              householdId: householdIdStr,
                                              otherUid: otherUid!,
                                              visibleOwnExpenseIds:
                                                  visibleOwnExpenseIds,
                                            );

                                        return FutureBuilder<
                                          _DashboardSecondaryMetadata
                                        >(
                                          future: secondaryMetadataFuture,
                                          builder: (
                                            context,
                                            secondaryMetaSnapshot,
                                          ) {
                                            final secondaryMetadataScopeKey =
                                                '$householdIdStr|$otherUid';
                                            final secondaryMetadata =
                                                secondaryMetaSnapshot.data;
                                            final secondaryMetadataReady =
                                                secondaryMetaSnapshot
                                                        .connectionState ==
                                                    ConnectionState.done &&
                                                secondaryMetadata != null;
                                            if (secondaryMetadataReady) {
                                              _lastVisibleDashboardSecondaryMetadataScopeKey =
                                                  secondaryMetadataScopeKey;
                                              _lastVisibleDashboardSecondaryMetadata =
                                                  secondaryMetadata;
                                            }
                                            final visibleSecondaryMetadata =
                                                secondaryMetadataReady
                                                ? secondaryMetadata
                                                : (_lastVisibleDashboardSecondaryMetadataScopeKey ==
                                                          secondaryMetadataScopeKey
                                                      ? _lastVisibleDashboardSecondaryMetadata
                                                      : null);
                                            _reportPreviewReady(
                                              secondaryMetadataReady,
                                            );
                                            final visibleOtherName =
                                                visibleSecondaryMetadata
                                                    ?.otherName;
                                            final visibleNotes =
                                                visibleSecondaryMetadata
                                                    ?.notesByExpenseId ??
                                                const <String, String>{};
                                            final balanceBreakdownText =
                                                visibleOtherName == null
                                                ? null
                                                : '$myName ${_formatEur(myPaidCents)} • $visibleOtherName ${_formatEur(otherPaidCents)}';

                                            String? visibleStatusText;
                                            if (pendingInCents != null &&
                                                pendingInCents > 0) {
                                              visibleStatusText =
                                                  '${_formatEur(pendingInCents)} ontvangen? Tik om te bevestigen';
                                            } else if (pendingOutCents != null &&
                                                pendingOutCents > 0) {
                                              visibleStatusText =
                                                  '${_formatEur(pendingOutCents)} gemeld · wacht op bevestiging';
                                            } else if (balanceCents > 0 &&
                                                visibleOtherName != null) {
                                              visibleStatusText =
                                                  '$visibleOtherName betaalt jou ${_formatEur(absBalance)}';
                                            } else if (balanceCents < 0 &&
                                                visibleOtherName != null) {
                                              visibleStatusText =
                                                  'Jij betaalt $visibleOtherName ${_formatEur(absBalance)}';
                                            } else if (balanceCents == 0) {
                                              visibleStatusText =
                                                  'Jullie zijn in balans';
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
                                                        a50,
                                                      ),
                                                    ),
                                              ),
                                              const SizedBox(height: 10),
                                            ],
                                            KiduCard(
                                              padding: EdgeInsets.zero,
                                              child: Material(
                                                type: MaterialType.transparency,
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      _DashboardPageState
                                                          ._cardRadius,
                                                    ),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        _DashboardPageState
                                                            ._cardRadius,
                                                      ),
                                                  highlightColor:
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withValues(
                                                            alpha: 0.10,
                                                          ),
                                                  splashColor: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.08),
                                                  onTap: () {
                                                    if (_pendingIncoming !=
                                                            null &&
                                                        _pendingIncomingId !=
                                                            null) {
                                                      final inPayment =
                                                          _pendingIncoming!;
                                                      final inId =
                                                          _pendingIncomingId!;
                                                      final inCents =
                                                          (inPayment['amountCents']
                                                                  as num?)
                                                              ?.toInt() ??
                                                          0;
                                                      showModalBottomSheet<
                                                        void
                                                      >(
                                                        context: context,
                                                        isScrollControlled:
                                                            true,
                                                        shape: const RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius.vertical(
                                                                top:
                                                                    Radius.circular(
                                                                      20,
                                                                    ),
                                                              ),
                                                        ),
                                                        builder: (sheetCtx) {
                                                          return SafeArea(
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.fromLTRB(
                                                                    24,
                                                                    20,
                                                                    24,
                                                                    28,
                                                                  ),
                                                              child: Column(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .stretch,
                                                                children: [
                                                                  Center(
                                                                    child: Container(
                                                                      width: 36,
                                                                      height: 4,
                                                                      decoration: BoxDecoration(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.outlineVariant,
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              2,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 20,
                                                                  ),
                                                                  Text(
                                                                    'Ontvangst bevestigen',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .titleMedium
                                                                        ?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w700,
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 16,
                                                                  ),
                                                                  Text(
                                                                    'Betaling gemeld door $otherName',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .bodyMedium
                                                                        ?.copyWith(
                                                                          color: onSurface(
                                                                            context,
                                                                            a84,
                                                                          ),
                                                                          height:
                                                                              1.4,
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 4,
                                                                  ),
                                                                  Text(
                                                                    _formatEur(
                                                                      inCents,
                                                                    ),
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .titleSmall
                                                                        ?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                          color: onSurface(
                                                                            context,
                                                                            a84,
                                                                          ),
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 20,
                                                                  ),
                                                                  FilledButton(
                                                                    onPressed: () {
                                                                      Navigator.of(
                                                                        sheetCtx,
                                                                      ).pop();
                                                                      showDialog<bool>(
                                                                        context:
                                                                            context,
                                                                        builder:
                                                                            (
                                                                              dialogCtx,
                                                                            ) => AlertDialog(
                                                                              title: const Text(
                                                                                'Ontvangst bevestigen',
                                                                              ),
                                                                              content: Text(
                                                                                'Je bevestigt dat je ${_formatEur(inCents)} van $otherName hebt ontvangen.',
                                                                              ),
                                                                              actions: [
                                                                                TextButton(
                                                                                  onPressed: () =>
                                                                                      Navigator.of(
                                                                                        dialogCtx,
                                                                                      ).pop(
                                                                                        false,
                                                                                      ),
                                                                                  child: const Text(
                                                                                    'Annuleren',
                                                                                  ),
                                                                                ),
                                                                                FilledButton(
                                                                                  onPressed: () =>
                                                                                      Navigator.of(
                                                                                        dialogCtx,
                                                                                      ).pop(
                                                                                        true,
                                                                                      ),
                                                                                  child: const Text(
                                                                                    'Bevestigen',
                                                                                  ),
                                                                                ),
                                                                              ],
                                                                            ),
                                                                      ).then((
                                                                        confirmed,
                                                                      ) async {
                                                                        if (confirmed ==
                                                                            true) {
                                                                          try {
                                                                            await FirebaseFirestore.instance
                                                                                .doc(
                                                                                  'households/$householdIdStr/payments/$inId',
                                                                                )
                                                                                .update({
                                                                                  'status': 'confirmed',
                                                                                  'confirmedAt': FieldValue.serverTimestamp(),
                                                                                  'confirmedBy': user.uid,
                                                                                });
                                                                            _showSnackBar(
                                                                              'Ontvangst bevestigd.',
                                                                            );
                                                                          } catch (
                                                                            e
                                                                          ) {
                                                                            if (kDebugMode) {
                                                                              debugPrint(
                                                                                'Payment confirm error: $e',
                                                                              );
                                                                            }
                                                                            _showSnackBar(
                                                                              mapUserFacingError(
                                                                                e,
                                                                                fallback: 'Bevestiging kon niet worden opgeslagen.',
                                                                              ),
                                                                            );
                                                                          }
                                                                        }
                                                                      });
                                                                    },
                                                                    child: const Text(
                                                                      'Ontvangst bevestigen',
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                      );
                                                      return;
                                                    }

                                                    if (_pendingOutgoing !=
                                                        null) {
                                                      final outPayment =
                                                          _pendingOutgoing!;
                                                      final outCents =
                                                          (outPayment['amountCents']
                                                                  as num?)
                                                              ?.toInt() ??
                                                          0;
                                                      showModalBottomSheet<
                                                        void
                                                      >(
                                                        context: context,
                                                        shape: const RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius.vertical(
                                                                top:
                                                                    Radius.circular(
                                                                      20,
                                                                    ),
                                                              ),
                                                        ),
                                                        builder: (sheetCtx) {
                                                          return SafeArea(
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.fromLTRB(
                                                                    24,
                                                                    20,
                                                                    24,
                                                                    28,
                                                                  ),
                                                              child: Column(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .stretch,
                                                                children: [
                                                                  Center(
                                                                    child: Container(
                                                                      width: 36,
                                                                      height: 4,
                                                                      decoration: BoxDecoration(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.outlineVariant,
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              2,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 20,
                                                                  ),
                                                                  Text(
                                                                    'Betaling melden',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .titleMedium
                                                                        ?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w700,
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 16,
                                                                  ),
                                                                  Text(
                                                                    'Betaling gemeld',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .bodyMedium
                                                                        ?.copyWith(
                                                                          color: onSurface(
                                                                            context,
                                                                            a84,
                                                                          ),
                                                                          height:
                                                                              1.4,
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 4,
                                                                  ),
                                                                  Text(
                                                                    '${_formatEur(outCents)} aan $otherName',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .titleSmall
                                                                        ?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                          color: onSurface(
                                                                            context,
                                                                            a84,
                                                                          ),
                                                                        ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 8,
                                                                  ),
                                                                  Text(
                                                                    'Wacht op bevestiging door $otherName',
                                                                    style: Theme.of(context)
                                                                        .textTheme
                                                                        .bodySmall
                                                                        ?.copyWith(
                                                                          color: onSurface(
                                                                            context,
                                                                            a62,
                                                                          ),
                                                                          height:
                                                                              1.4,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                      );
                                                      return;
                                                    }

                                                    final amountCtrl =
                                                        TextEditingController(
                                                          text:
                                                              '${absBalance ~/ 100},${(absBalance % 100).toString().padLeft(2, '0')}',
                                                        );
                                                    int? enteredCents =
                                                        absBalance;
                                                    showModalBottomSheet<void>(
                                                      context: context,
                                                      isScrollControlled: true,
                                                      shape: const RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.vertical(
                                                              top:
                                                                  Radius.circular(
                                                                    20,
                                                                  ),
                                                            ),
                                                      ),
                                                      builder: (sheetCtx) {
                                                        return StatefulBuilder(
                                                          builder: (_, setSheetState) {
                                                            final isValid =
                                                                enteredCents !=
                                                                    null &&
                                                                enteredCents! >
                                                                    0;
                                                            final bottomInset =
                                                                MediaQuery.of(
                                                                      sheetCtx,
                                                                    )
                                                                    .viewInsets
                                                                    .bottom;
                                                            return SafeArea(
                                                              child: Padding(
                                                                padding:
                                                                    EdgeInsets.fromLTRB(
                                                                      24,
                                                                      20,
                                                                      24,
                                                                      28 +
                                                                          bottomInset,
                                                                    ),
                                                                child: Column(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  crossAxisAlignment:
                                                                      CrossAxisAlignment
                                                                          .stretch,
                                                                  children: [
                                                                    Center(
                                                                      child: Container(
                                                                        width:
                                                                            36,
                                                                        height:
                                                                            4,
                                                                        decoration: BoxDecoration(
                                                                          color: Theme.of(
                                                                            context,
                                                                          ).colorScheme.outlineVariant,
                                                                          borderRadius:
                                                                              BorderRadius.circular(
                                                                                2,
                                                                              ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      height:
                                                                          20,
                                                                    ),
                                                                    Text(
                                                                      balanceCents <
                                                                              0
                                                                          ? 'Betaling melden'
                                                                          : 'Balans',
                                                                      style: Theme.of(context)
                                                                          .textTheme
                                                                          .titleMedium
                                                                          ?.copyWith(
                                                                            fontWeight:
                                                                                FontWeight.w700,
                                                                          ),
                                                                    ),
                                                                    const SizedBox(
                                                                      height:
                                                                          16,
                                                                    ),
                                                                    if (balanceCents ==
                                                                        0)
                                                                      Text(
                                                                        'Jullie zijn in balans',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodyMedium?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a62,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      )
                                                                    else if (balanceCents >
                                                                        0) ...[
                                                                      Text(
                                                                        '$otherName is jou nog ${_formatEur(absBalance)} schuldig',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodyMedium?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            8,
                                                                      ),
                                                                      Text(
                                                                        '$otherName kan een betaling melden vanuit de app.',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodySmall?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a62,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      ),
                                                                    ] else ...[
                                                                      Text(
                                                                        'Open bedrag: ${_formatEur(absBalance)}',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.titleSmall?.copyWith(
                                                                              fontWeight: FontWeight.w600,
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            4,
                                                                      ),
                                                                      Text(
                                                                        'Jij betaalt $otherName',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodySmall?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a62,
                                                                              ),
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            16,
                                                                      ),
                                                                      TextField(
                                                                        controller:
                                                                            amountCtrl,
                                                                        keyboardType: const TextInputType.numberWithOptions(
                                                                          decimal:
                                                                              true,
                                                                        ),
                                                                        decoration: InputDecoration(
                                                                          labelText:
                                                                              'Bedrag',
                                                                          prefixText:
                                                                              '€ ',
                                                                          isDense:
                                                                              true,
                                                                          border:
                                                                              const OutlineInputBorder(),
                                                                          errorText:
                                                                              amountCtrl.text.trim().isNotEmpty &&
                                                                                  (enteredCents ==
                                                                                          null ||
                                                                                      enteredCents! <=
                                                                                          0)
                                                                              ? 'Voer een geldig bedrag in'
                                                                              : null,
                                                                        ),
                                                                        onChanged: (val) {
                                                                          setSheetState(() {
                                                                            enteredCents = _tryParseEurToCents(
                                                                              val,
                                                                            );
                                                                          });
                                                                        },
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            20,
                                                                      ),
                                                                      FilledButton(
                                                                        onPressed:
                                                                            isValid
                                                                            ? () {
                                                                                final paymentAmountCents = enteredCents!;
                                                                                Navigator.of(
                                                                                  sheetCtx,
                                                                                ).pop();
                                                                                showDialog<
                                                                                      bool
                                                                                    >(
                                                                                      context: context,
                                                                                      builder:
                                                                                          (
                                                                                            dialogCtx,
                                                                                          ) => AlertDialog(
                                                                                            title: const Text(
                                                                                              'Betaling melden',
                                                                                            ),
                                                                                            content: Text(
                                                                                              'Je meldt een betaling van ${_formatEur(enteredCents!)} aan $otherName. $otherName moet dit nog bevestigen.',
                                                                                            ),
                                                                                            actions: [
                                                                                              TextButton(
                                                                                                onPressed: () =>
                                                                                                    Navigator.of(
                                                                                                      dialogCtx,
                                                                                                    ).pop(
                                                                                                      false,
                                                                                                    ),
                                                                                                child: const Text(
                                                                                                  'Annuleren',
                                                                                                ),
                                                                                              ),
                                                                                              FilledButton(
                                                                                                onPressed: () =>
                                                                                                    Navigator.of(
                                                                                                      dialogCtx,
                                                                                                    ).pop(
                                                                                                      true,
                                                                                                    ),
                                                                                                child: const Text(
                                                                                                  'Melden',
                                                                                                ),
                                                                                              ),
                                                                                            ],
                                                                                          ),
                                                                                    )
                                                                                    .then(
                                                                                      (
                                                                                        confirmed,
                                                                                      ) async {
                                                                                        if (confirmed ==
                                                                                            true) {
                                                                                          try {
                                                                                            await FirebaseFirestore.instance
                                                                                                .collection(
                                                                                                  'households/$householdIdStr/payments',
                                                                                                )
                                                                                                .add(
                                                                                                  {
                                                                                                    'amountCents': paymentAmountCents,
                                                                                                    'currency': 'EUR',
                                                                                                    'fromUserId': user.uid,
                                                                                                    'toUserId': otherUid!,
                                                                                                    'status': 'pending',
                                                                                                    'createdAt': FieldValue.serverTimestamp(),
                                                                                                    'createdBy': user.uid,
                                                                                                    'confirmedAt': null,
                                                                                                    'confirmedBy': null,
                                                                                                  },
                                                                                                );
                                                                                            _showSnackBar(
                                                                                              'Betaling gemeld — wacht op bevestiging.',
                                                                                            );
                                                                                          } catch (
                                                                                            e
                                                                                          ) {
                                                                                            if (kDebugMode) {
                                                                                              debugPrint(
                                                                                                'Payment write error: $e',
                                                                                              );
                                                                                            }
                                                                                            _showSnackBar(
                                                                                              mapUserFacingError(
                                                                                                e,
                                                                                                fallback: 'Betaling kon niet worden gemeld.',
                                                                                              ),
                                                                                            );
                                                                                          }
                                                                                        }
                                                                                      },
                                                                                    );
                                                                              }
                                                                            : null,
                                                                        child: const Text(
                                                                          'Betaling melden',
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        );
                                                      },
                                                    );
                                                  },
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          16,
                                                        ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .stretch,
                                                      children: [
                                                        Text(
                                                          'Balans',
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .titleMedium
                                                              ?.copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                        ),
                                                        // Compact summary: replace three separate rows.
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        _balanceRow(
                                                          label:
                                                              'Totaal samen uitgegeven',
                                                          value: _formatEur(
                                                            totalCents,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Text(
                                                          balanceBreakdownText ??
                                                              ' ',
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color:
                                                                    onSurface(
                                                                      context,
                                                                      a62,
                                                                    ),
                                                                height: 1.3,
                                                              ),
                                                        ),
                                                        // Tighter section spacing for lower card height.
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Divider(
                                                          height: 1,
                                                          color: outlineV(
                                                            context,
                                                            a40,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Text(
                                                          visibleStatusText ??
                                                              ' ',
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                color:
                                                                    onSurface(
                                                                      context,
                                                                      a84,
                                                                    ),
                                                                height: 1.3,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: _cardGap),
                                            KiduCard(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 12,
                                                  ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  Text(
                                                    'Recente uitgaven',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  docs.isEmpty
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
                                                          shrinkWrap: true,
                                                          padding:
                                                              EdgeInsets.zero,
                                                          physics:
                                                              const NeverScrollableScrollPhysics(),
                                                          itemCount:
                                                              visibleDocs.length,
                                                          separatorBuilder:
                                                              (
                                                                context,
                                                                index,
                                                              ) => Divider(
                                                                height: 14,
                                                                color: outlineV(
                                                                  context,
                                                                  a40,
                                                                ),
                                                              ),
                                                          itemBuilder: (context, index) {
                                                            final d =
                                                                visibleDocs[index];
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
                                                            final rowFallback =
                                                                createdBy ==
                                                                        user.uid &&
                                                                    _pendingExpenseRowFallback
                                                                            ?.expenseId ==
                                                                        d.id
                                                                ? _pendingExpenseRowFallback
                                                                : null;
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
                                                            createdAtDateTime ??=
                                                                rowFallback
                                                                    ?.savedAt
                                                                    .toLocal();
                                                            final dateLabel =
                                                                _formatDashboardExpenseDate(
                                                                  createdAtDateTime,
                                                                );
                                                            final actorLabel =
                                                                (createdBy ==
                                                                        user.uid)
                                                                ? myName
                                                                : (otherUid !=
                                                                          null &&
                                                                      createdBy ==
                                                                          otherUid)
                                                                ? visibleOtherName
                                                                : null;
                                                            final baseSubtitleText =
                                                                actorLabel ==
                                                                        null ||
                                                                    actorLabel
                                                                        .isEmpty
                                                                ? dateLabel
                                                                : dateLabel
                                                                      .isEmpty
                                                                ? actorLabel
                                                                : '$actorLabel • $dateLabel';
                                                            final note =
                                                                visibleNotes[d.id] ??
                                                                rowFallback?.note;
                                                            final subtitleText =
                                                                note != null &&
                                                                        note.isNotEmpty
                                                                ? baseSubtitleText
                                                                          .isEmpty
                                                                    ? note
                                                                    : '$baseSubtitleText · $note'
                                                                : baseSubtitleText;
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

                                                            Future<void>
                                                            openNoteFlow() async {
                                                              final hasNote =
                                                                  (visibleNotes[d.id] ??
                                                                          '')
                                                                      .isNotEmpty;
                                                              if (!await _checkCanWriteNow()) {
                                                                if (mounted) {
                                                                  _showSnackBar(
                                                                    hasNote
                                                                        ? 'Je bent offline. Notitie wijzigen kan alleen met internet.'
                                                                        : 'Je bent offline. Notitie toevoegen kan alleen met internet.',
                                                                  );
                                                                }
                                                                return;
                                                              }
                                                              await _openEditPrivateNoteDialog(
                                                                householdId:
                                                                    householdIdStr,
                                                                expenseId:
                                                                    d.id,
                                                                uid: user.uid,
                                                              );
                                                            }

                                                            return Material(
                                                              type: MaterialType
                                                                  .transparency,
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: InkWell(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      8,
                                                                    ),
                                                                highlightColor:
                                                                    Theme.of(
                                                                      context,
                                                                    ).colorScheme.primary.withValues(
                                                                      alpha:
                                                                          0.10,
                                                                    ),
                                                                splashColor:
                                                                    Theme.of(
                                                                      context,
                                                                    ).colorScheme.primary.withValues(
                                                                      alpha:
                                                                          0.08,
                                                                    ),
                                                                onTap: () async {
                                                                  final preloadedChildNames =
                                                                      expChildIds.isEmpty
                                                                      ? const <String>[]
                                                                      : (_dashChildren
                                                                                .isNotEmpty &&
                                                                            expChildIds.every(
                                                                              (
                                                                                id,
                                                                              ) => _dashChildren.any(
                                                                                (
                                                                                  c,
                                                                                ) =>
                                                                                    c.id ==
                                                                                    id,
                                                                              ),
                                                                            ))
                                                                      ? expChildIds
                                                                            .map(
                                                                              (
                                                                                id,
                                                                              ) =>
                                                                                  _dashChildren
                                                                                      .where(
                                                                                        (
                                                                                          c,
                                                                                        ) =>
                                                                                            c.id ==
                                                                                            id,
                                                                                      )
                                                                                      .map(
                                                                                        (
                                                                                          c,
                                                                                        ) => c.name,
                                                                                      )
                                                                                      .firstOrNull ??
                                                                                  'Verwijderd kind',
                                                                            )
                                                                            .toList()
                                                                      : await _ExpenseDetailPage._resolveChildNames(
                                                                          householdIdStr,
                                                                          expChildIds,
                                                                        );
                                                                  if (!context.mounted) {
                                                                    return;
                                                                  }
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
                                                                            createdByUid:
                                                                                createdBy ??
                                                                                '',
                                                                            title: title,
                                                                            amountCents: amountCents,
                                                                            paidByName: who,
                                                                            createdAt: createdAtDateTime,
                                                                            isPending: isPending,
                                                                            onManageNote: createdBy == user.uid
                                                                                ? openNoteFlow
                                                                                : null,
                                                                            otherParentName: otherName,
                                                                            childIds: expChildIds,
                                                                            childNames:
                                                                                preloadedChildNames,
                                                                          ),
                                                                    ),
                                                                  );
                                                                },
                                                                child: ListTile(
                                                                  contentPadding:
                                                                      const EdgeInsets.symmetric(
                                                                        horizontal:
                                                                            5,
                                                                      ),
                                                                  dense: true,
                                                                  visualDensity:
                                                                      VisualDensity
                                                                          .compact,
                                                                  title: Text(
                                                                    title,
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                  subtitle:
                                                                      subtitleText
                                                                              .isEmpty
                                                                          ? null
                                                                          : Text(
                                                                              subtitleText,
                                                                              maxLines: 1,
                                                                              overflow: TextOverflow.ellipsis,
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
                                                                            size:
                                                                                16,
                                                                            color:
                                                                                onSurface(
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
                                                                        style: Theme.of(
                                                                          context,
                                                                        ).textTheme.bodyMedium?.copyWith(
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        );
                                      },
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
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

Future<List<_ChildItem>> _loadExpenseEditChildren(String householdId) async {
  final snap = await FirebaseFirestore.instance
      .collection('households/$householdId/children')
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
  return docs
      .map(
        (d) => _ChildItem(
          id: d.id,
          name: (d.data()['name'] as String?)?.trim() ?? '?',
        ),
      )
      .toList();
}

Future<List<String>?> _showExpenseEditChildSelectionDialog(
  BuildContext context, {
  required List<_ChildItem> children,
  List<String> initialSelectedChildIds = const [],
}) async {
  final allChildIds = children.map((c) => c.id).toList(growable: false);
  return showDialog<List<String>>(
    context: context,
    useSafeArea: true,
    barrierDismissible: true,
    builder: (context) {
      var selectedChildIds = initialSelectedChildIds
          .where(allChildIds.contains)
          .toSet();
      return StatefulBuilder(
        builder: (context, setLocalState) {
          final selectedCount = selectedChildIds.length;
          final allSelected = selectedCount == allChildIds.length;
          final cs = Theme.of(context).colorScheme;
          final dialogBackground = cs.surfaceContainerHigh;
          final screenW = MediaQuery.sizeOf(context).width;
          final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
          final modalHeight = min(
            520.0,
            MediaQuery.of(context).size.height - 36,
          );
          void dismissSelectionDialog() => Navigator.of(context).pop();
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            child: SafeArea(
              child: Align(
                alignment: const Alignment(0, -0.08),
                child: SizedBox(
                  width: dialogW,
                  child: SizedBox(
                    height: modalHeight,
                    child: Material(
                      color: dialogBackground,
                      elevation: 3,
                      clipBehavior: Clip.antiAlias,
                      borderRadius: BorderRadius.circular(
                        _DashboardPageState._cardRadius,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            _DashboardPageState._cardRadius,
                          ),
                          border: Border.all(color: outlineV(context, a40)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              child: Center(
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.85,
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: Text(
                                'Selectie',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w400,
                                      color: onSurface(context, a84),
                                    ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  0,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextButton(
                                      onPressed: () => setLocalState(() {
                                        selectedChildIds = allSelected
                                            ? <String>{}
                                            : allChildIds.toSet();
                                      }),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: Text(
                                        allSelected
                                            ? 'Alles deselecteren'
                                            : 'Alles selecteren',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      height: 28,
                                      child: Align(
                                        alignment: Alignment.topLeft,
                                        child: Opacity(
                                          opacity: selectedCount == 0 ? 1 : 0,
                                          child: Text(
                                            'Selecteer minimaal 1 kind om verder te gaan',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall?.copyWith(
                                              color: onSurface(context, a68),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: ListView.separated(
                                        padding: const EdgeInsets.only(
                                          top: 2,
                                          bottom: 4,
                                        ),
                                        itemCount: children.length,
                                        separatorBuilder: (_, _) => Divider(
                                          height: 1,
                                          thickness: 0.4,
                                          color: cs.outlineVariant.withValues(
                                            alpha: 0.45,
                                          ),
                                        ),
                                        itemBuilder: (context, index) {
                                          final child = children[index];
                                          final selected = selectedChildIds
                                              .contains(child.id);
                                          return Material(
                                            type: MaterialType.transparency,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () {
                                                setLocalState(() {
                                                  if (selected) {
                                                    selectedChildIds =
                                                        selectedChildIds
                                                            .where(
                                                              (id) =>
                                                                  id != child.id,
                                                            )
                                                            .toSet();
                                                  } else {
                                                    selectedChildIds = {
                                                      ...selectedChildIds,
                                                      child.id,
                                                    };
                                                  }
                                                });
                                              },
                                              child: ListTile(
                                                dense: true,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                minLeadingWidth: 32,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 2,
                                                      vertical: 0,
                                                    ),
                                                leading: Checkbox(
                                                  value: selected,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  activeColor: cs.primary
                                                      .withValues(alpha: a84),
                                                  checkColor: cs.surface,
                                                  side: BorderSide(
                                                    color: cs.outlineVariant
                                                        .withValues(
                                                          alpha: 0.85,
                                                        ),
                                                  ),
                                                  onChanged: (value) {
                                                    setLocalState(() {
                                                      if (value ?? false) {
                                                        selectedChildIds = {
                                                          ...selectedChildIds,
                                                          child.id,
                                                        };
                                                      } else {
                                                        selectedChildIds =
                                                            selectedChildIds
                                                                .where(
                                                                  (id) =>
                                                                      id !=
                                                                      child.id,
                                                                )
                                                                .toSet();
                                                      }
                                                    });
                                                  },
                                                ),
                                                title: Text(
                                                  child.name,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color: onSurface(
                                                          context,
                                                          a84,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: dialogBackground,
                                border: Border(
                                  top: BorderSide(
                                    color: outlineV(context, a32),
                                  ),
                                ),
                              ),
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    12,
                                  ),
                                  child: Row(
                                    children: [
                                      TextButton(
                                        onPressed: dismissSelectionDialog,
                                        child: const Text('Annuleren'),
                                      ),
                                      const Spacer(),
                                      ElevatedButton(
                                        onPressed: selectedCount == 0
                                            ? null
                                            : () => Navigator.of(context).pop(
                                                children
                                                    .where(
                                                      (child) =>
                                                          selectedChildIds
                                                              .contains(
                                                                child.id,
                                                              ),
                                                    )
                                                    .map((child) => child.id)
                                                    .toList(),
                                              ),
                                        child: const Text('Gereed'),
                                      ),
                                    ],
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
              ),
            ),
          );
        },
      );
    },
  );
}

class _ExpenseDetailPage extends StatefulWidget {
  const _ExpenseDetailPage({
    required this.householdId,
    required this.expenseId,
    required this.uid,
    required this.createdByUid,
    required this.title,
    required this.amountCents,
    required this.paidByName,
    required this.createdAt,
    required this.isPending,
    this.onManageNote,
    this.childIds = const [],
    this.childNames,
    this.otherParentName,
  });

  final String householdId;
  final String expenseId;
  final String uid;
  final String createdByUid;
  final String title;
  final int amountCents;
  final String paidByName;
  final DateTime? createdAt;
  final bool isPending;
  final Future<void> Function()? onManageNote;
  final String? otherParentName;
  final List<String> childIds;
  // Pre-resolved display names; when non-null the Voor section renders
  // synchronously without a FutureBuilder round-trip.
  final List<String>? childNames;

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
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
  }

  static String _prefillAmountForEdit(int cents) {
    final euros = cents ~/ 100;
    final rem = cents % 100;
    return '$euros,${rem.toString().padLeft(2, '0')}';
  }

  /// Same rules as [DashboardPage._tryParseEurToCents] (single-file).
  static int? _parseEurToCents(String input) {
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
    return '${dt.day} ${nlMonths[dt.month - 1]} \u2022 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  State<_ExpenseDetailPage> createState() => _ExpenseDetailPageState();
}

/// Owns [TextEditingController]s so they are disposed with the route, not
/// immediately after [showDialog] returns (avoids teardown races).
class _EditExpenseAmountDialog extends StatefulWidget {
  const _EditExpenseAmountDialog({
    required this.householdId,
    required this.expenseId,
    required this.currentAmountCents,
    required this.currentTitle,
    required this.currentChildIds,
    required this.childrenFuture,
  });

  final String householdId;
  final String expenseId;
  final int currentAmountCents;
  final String currentTitle;
  final List<String> currentChildIds;
  final Future<List<_ChildItem>> childrenFuture;

  @override
  State<_EditExpenseAmountDialog> createState() =>
      _EditExpenseAmountDialogState();
}

class _EditExpenseAmountDialogState extends State<_EditExpenseAmountDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _reasonController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _amountFocusNode;
  late final FocusNode _reasonFocusNode;
  late final Future<List<_ChildItem>> _childrenFuture;
  bool _showReasonField = false;
  bool _showNoChangesMessage = false;
  bool _titleHasError = false;
  bool _amountHasError = false;
  bool _reasonHasError = false;
  bool _didChangeChildSelection = false;
  bool _hasCustomChildSelection = false;
  List<String> _customSelectedChildIds = const <String>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.currentTitle);
    _amountController = TextEditingController(
      text: _ExpenseDetailPage._prefillAmountForEdit(widget.currentAmountCents),
    );
    _reasonController = TextEditingController();
    _titleFocusNode = FocusNode();
    _amountFocusNode = FocusNode();
    _reasonFocusNode = FocusNode();
    _childrenFuture = widget.childrenFuture;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _reasonController.dispose();
    _titleFocusNode.dispose();
    _amountFocusNode.dispose();
    _reasonFocusNode.dispose();
    super.dispose();
  }

  List<String> _allChildIds(List<_ChildItem> children) =>
      children.map((c) => c.id).toList(growable: false);

  bool _isAllChildrenSelection(List<_ChildItem> children, List<String> childIds) {
    final allChildIds = _allChildIds(children);
    return allChildIds.isNotEmpty &&
        childIds.length == allChildIds.length &&
        childIds.toSet().containsAll(allChildIds);
  }

  List<String> _currentKnownChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    return widget.currentChildIds.where(allChildIds.contains).toList();
  }

  List<String> _effectiveSelectedChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    if (!_didChangeChildSelection) {
      return _isAllChildrenSelection(children, widget.currentChildIds)
          ? allChildIds
          : _currentKnownChildIds(children);
    }
    return _hasCustomChildSelection ? _customSelectedChildIds : allChildIds;
  }

  List<String> _dialogInitialSelectedChildIds(List<_ChildItem> children) {
    if (_didChangeChildSelection) {
      return _hasCustomChildSelection ? _customSelectedChildIds : const [];
    }
    return _isAllChildrenSelection(children, widget.currentChildIds)
        ? const []
        : _currentKnownChildIds(children);
  }

  bool _sameChildIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  Future<void> _openChildSelectionDialog(List<_ChildItem> children) async {
    final pickedChildIds = await _showExpenseEditChildSelectionDialog(
      context,
      children: children,
      initialSelectedChildIds: _dialogInitialSelectedChildIds(children),
    );
    if (pickedChildIds == null || !mounted) return;
    setState(() {
      _showNoChangesMessage = false;
      _didChangeChildSelection = true;
      if (pickedChildIds.length == children.length) {
        _hasCustomChildSelection = false;
        _customSelectedChildIds = const <String>[];
      } else {
        _hasCustomChildSelection = true;
        _customSelectedChildIds = pickedChildIds;
      }
    });
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final reasonTrimmed = _reasonController.text.trim();
    final parsed = _ExpenseDetailPage._parseEurToCents(_amountController.text);
    final children = await _childrenFuture;
    final effectiveSelectedChildIds = _effectiveSelectedChildIds(children);
    if (title.isEmpty) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (title.length > _kAddExpenseTitleMaxLength) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (parsed == null || parsed < 0) {
      if (mounted) {
        setState(() => _amountHasError = true);
        _amountFocusNode.requestFocus();
      }
      return;
    }
    if (children.length > 1 && effectiveSelectedChildIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecteer minimaal één kind.')),
      );
      return;
    }
    setState(() => _saving = true);
    if (!await _checkCanWriteNow()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Je bent offline, probeer het later opnieuw'),
        ),
      );
      setState(() => _saving = false);
      return;
    }
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final expRef = FirebaseFirestore.instance.doc(
        'households/${widget.householdId}/expenses/${widget.expenseId}',
      );
      final fresh = await expRef.get(const GetOptions(source: Source.server));
      final currentTitle =
          ((fresh.data()?['title'] as String?) ?? widget.currentTitle).trim();
      final currentChildIds =
          (fresh.data()?['childIds'] as List?)?.whereType<String>().toList() ??
          widget.currentChildIds;
      final fromCents =
          (fresh.data()?['amountCents'] as num?)?.toInt() ??
          widget.currentAmountCents;
      final titleChanged = title != currentTitle;
      final amountChanged = parsed != fromCents;
      final childIdsChanged =
          !_sameChildIds(effectiveSelectedChildIds, currentChildIds);
      if (!amountChanged && !titleChanged && !childIdsChanged) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _showNoChangesMessage = true;
        });
        return;
      }
      if (amountChanged) {
        if (reasonTrimmed.isEmpty) {
          if (mounted) {
            setState(() => _reasonHasError = true);
            _reasonFocusNode.requestFocus();
          }
          setState(() => _saving = false);
          return;
        }
        final batch = FirebaseFirestore.instance.batch();
        final editRef = expRef.collection('amountEdits').doc();
        batch.set(editRef, {
          'fromAmountCents': fromCents,
          'toAmountCents': parsed,
          'reason': reasonTrimmed,
          'editedBy': uid,
          'editedAt': FieldValue.serverTimestamp(),
        });
        batch.update(expRef, {
          'amountCents': parsed,
          if (titleChanged) 'title': title,
          if (childIdsChanged) 'childIds': effectiveSelectedChildIds,
        });
        await batch.commit();
      } else {
        await expRef.update({
          'title': title,
          if (childIdsChanged) 'childIds': effectiveSelectedChildIds,
        });
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Edit expense amount error: $e');
      }
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Opslaan mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
    final subtleErrorHintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.error.withValues(alpha: 0.85),
      fontSize: 12,
      fontWeight: FontWeight.w400,
    );
    final subtleErrorInputStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: Theme.of(context).colorScheme.error.withValues(alpha: 0.88),
      fontWeight: FontWeight.w400,
    );
    final titleTrimmed = _titleController.text.trim();
    final titleErrorHint = titleTrimmed.isEmpty
        ? 'Vul een titel in'
        : 'Titel mag maximaal $_kAddExpenseTitleMaxLength tekens hebben.';
    return Align(
      alignment: const Alignment(0, -0.15),
      child: SizedBox(
        width: dialogW,
        child: AlertDialog(
          title: const Text('Uitgave bewerken'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                TextField(
                  controller: _titleController,
                  focusNode: _titleFocusNode,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  maxLength: _kAddExpenseTitleMaxLength,
                  onTap: () {
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  onChanged: (_) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  buildCounter:
                      (
                        context, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => null,
                  decoration: InputDecoration(
                    labelText: 'Titel',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintText: _titleHasError ? titleErrorHint : null,
                    hintStyle: _titleHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountController,
                  focusNode: _amountFocusNode,
                  style: _amountHasError ? subtleErrorInputStyle : null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () {
                    if (_amountHasError) {
                      setState(() => _amountHasError = false);
                    }
                  },
                  onChanged: (value) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    final parsed = _ExpenseDetailPage._parseEurToCents(
                      _amountController.text,
                    );
                    final backToOriginal =
                        parsed != null && parsed == widget.currentAmountCents;
                    final validAndChanged =
                        parsed != null && parsed != widget.currentAmountCents;
                    final trimmed = value.trim();
                    final nextAmountHasError =
                        trimmed.isNotEmpty && (parsed == null || parsed < 0);
                    var shouldSetState = false;
                    final nextShowReasonField = validAndChanged;
                    if (nextShowReasonField != _showReasonField) {
                      shouldSetState = true;
                    }
                    if (nextAmountHasError != _amountHasError) {
                      shouldSetState = true;
                    }
                    if (backToOriginal &&
                        _showReasonField &&
                        _reasonController.text.isNotEmpty) {
                      _reasonController.clear();
                    }
                    if (shouldSetState) {
                      setState(() {
                        _showReasonField = nextShowReasonField;
                        _amountHasError = nextAmountHasError;
                      });
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: 'Nieuw bedrag (€)',
                  ),
                ),
                if (_showReasonField) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reasonController,
                    focusNode: _reasonFocusNode,
                    onTap: () {
                      if (_reasonHasError) {
                        setState(() => _reasonHasError = false);
                      }
                    },
                    onChanged: (_) {
                      if (_showNoChangesMessage) {
                        setState(() => _showNoChangesMessage = false);
                      }
                      if (_reasonHasError) {
                        setState(() => _reasonHasError = false);
                      }
                    },
                    minLines: 2,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'Reden',
                      alignLabelWithHint: true,
                      isDense: true,
                      hintText: _reasonHasError ? 'Vul een reden in' : null,
                      hintStyle: _reasonHasError ? subtleErrorHintStyle : null,
                    ),
                  ),
                ],
                FutureBuilder<List<_ChildItem>>(
                  future: _childrenFuture,
                  builder: (context, snap) {
                    final children = snap.data ?? const <_ChildItem>[];
                    if (children.length <= 1) return const SizedBox.shrink();
                    final effectiveSelectedChildIds =
                        _effectiveSelectedChildIds(children);
                    final childSelectionSummary =
                        _isAllChildrenSelection(
                              children,
                              effectiveSelectedChildIds,
                            )
                            ? 'Alle kinderen'
                            : '${effectiveSelectedChildIds.length} van ${children.length} geselecteerd';
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Voor:',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  childSelectionSummary,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              TextButton(
                                onPressed: _saving || !snap.hasData
                                    ? null
                                    : () async {
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                        await _openChildSelectionDialog(
                                          children,
                                        );
                                      },
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('Selectie'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
                if (_showNoChangesMessage)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Er zijn geen wijzigingen.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Annuleren'),
            ),
            ElevatedButton(
              onPressed: _saving ? null : () => _submit(),
              child: SizedBox(
                width: 82,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Text('Opslaan'),
                    if (_saving)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
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
  }
}

class _ExpenseDetailPageState extends State<_ExpenseDetailPage> {
  bool _noteActionBusy = false;
  List<String>? _resolvedChildNamesIds;
  Future<List<String>>? _resolvedChildNamesFuture;
  late final Future<List<_ChildItem>> _expenseEditChildrenFuture;

  @override
  void initState() {
    super.initState();
    _expenseEditChildrenFuture = _loadExpenseEditChildren(widget.householdId);
  }

  void _handleBack() {
    Navigator.of(context).pop();
  }

  void _showExpenseSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _sameChildIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String>? _initialChildNamesFor(List<String> currentChildIds) {
    final childNames = widget.childNames;
    if (childNames == null || childNames.length != currentChildIds.length) {
      return null;
    }
    if (!_sameChildIds(currentChildIds, widget.childIds)) {
      return null;
    }
    if (childNames.contains('Verwijderd kind')) {
      return null;
    }
    return childNames;
  }

  Future<List<String>> _childNamesFutureFor(List<String> currentChildIds) {
    if (_resolvedChildNamesIds != null &&
        _resolvedChildNamesFuture != null &&
        _sameChildIds(_resolvedChildNamesIds!, currentChildIds)) {
      return _resolvedChildNamesFuture!;
    }
    _resolvedChildNamesIds = List<String>.from(
      currentChildIds,
      growable: false,
    );
    _resolvedChildNamesFuture = _ExpenseDetailPage._resolveChildNames(
      widget.householdId,
      currentChildIds,
    );
    return _resolvedChildNamesFuture!;
  }

  Widget _buildChildTile(List<String> childNames) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Voor',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: onSurface(context, a70)),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: childNames
              .map(
                (n) => Chip(
                  label: Text(n),
                  labelStyle: Theme.of(context).textTheme.bodySmall,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Future<void> _openEditAmountDialog({
    required int currentAmountCents,
    required String currentTitle,
    required List<String> currentChildIds,
  }) async {
    if (!await _checkCanWriteNow()) {
      if (mounted) {
        _showExpenseSnackBar('Je bent offline, probeer het later opnieuw');
      }
      return;
    }
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      useSafeArea: true,
      barrierDismissible: false,
      builder: (context) => Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final keyboardVisible =
                      MediaQuery.of(context).viewInsets.bottom > 0;
                  if (keyboardVisible) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
                child: const SizedBox.expand(),
              ),
            ),
            GestureDetector(
              onTap: () {},
              child: _EditExpenseAmountDialog(
                householdId: widget.householdId,
                expenseId: widget.expenseId,
                currentAmountCents: currentAmountCents,
                currentTitle: currentTitle,
                currentChildIds: currentChildIds,
                childrenFuture: _expenseEditChildrenFuture,
              ),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showExpenseSnackBar('Uitgave bijgewerkt.');
      });
    }
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
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final ed = expSnap.data?.data();
                      final currentTitle =
                          ((ed?['title'] as String?) ?? widget.title).trim();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Titel',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: onSurface(context, a70),
                          ),
                        ),
                        subtitle: Text(
                          currentTitle.isEmpty ? widget.title : currentTitle,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Betaald door',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: Text(widget.paidByName),
                  ),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final ed = expSnap.data?.data();
                      final currentChildIds =
                          (ed?['childIds'] as List?)?.whereType<String>().toList() ??
                          widget.childIds;
                      if (currentChildIds.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      final initialChildNames = _initialChildNamesFor(
                        currentChildIds,
                      );
                      if (initialChildNames != null) {
                        return _buildChildTile(initialChildNames);
                      }
                      return FutureBuilder<List<String>>(
                        future: _childNamesFutureFor(currentChildIds),
                        builder: (context, snap) {
                          if (!snap.hasData) return const SizedBox.shrink();
                          return _buildChildTile(snap.data!);
                        },
                      );
                    },
                  ),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final ed = expSnap.data?.data();
                      final currentCents =
                          (ed?['amountCents'] as num?)?.toInt() ??
                          widget.amountCents;
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'Bedrag',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                              subtitle: Text(
                                _ExpenseDetailPage._formatEur(currentCents),
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .collection(
                          'households/${widget.householdId}/expenses/${widget.expenseId}/amountEdits',
                        )
                        .orderBy('editedAt', descending: true)
                        .snapshots(),
                    builder: (context, histSnap) {
                      if (histSnap.hasError) {
                        return const SizedBox.shrink();
                      }
                      if (!histSnap.hasData || histSnap.data!.docs.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      final docs = histSnap.data!.docs;
                      String editorLabel(String? editedByUid) {
                        final e = editedByUid?.trim() ?? '';
                        if (e.isEmpty) return 'Co-parent';
                        if (e == widget.uid) return 'Jij';
                        final o = widget.otherParentName?.trim();
                        if (o != null && o.isNotEmpty) return o;
                        return 'Co-parent';
                      }

                      return Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Wijzigingsgeschiedenis',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: onSurface(context, a70),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            ...docs.map((doc) {
                              final h = doc.data();
                              final fromC =
                                  (h['fromAmountCents'] as num?)?.toInt() ?? 0;
                              final toC =
                                  (h['toAmountCents'] as num?)?.toInt() ?? 0;
                              final reason =
                                  (h['reason'] as String?)?.trim() ?? '';
                              final editedBy = (h['editedBy'] as String?)
                                  ?.trim();
                              final editedAtRaw = h['editedAt'];
                              DateTime? editedAtDt;
                              if (editedAtRaw is Timestamp) {
                                editedAtDt = editedAtRaw.toDate().toLocal();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${_ExpenseDetailPage._formatEur(fromC)} → ${_ExpenseDetailPage._formatEur(toC)} · ${editorLabel(editedBy)} · ${_ExpenseDetailPage._formatDateTime(editedAtDt)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: onSurface(context, a68),
                                            height: 1.35,
                                          ),
                                    ),
                                    if (reason.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        reason,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(height: 1.35),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Datum/tijd',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: Text(
                      _ExpenseDetailPage._formatDateTime(widget.createdAt),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Status',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
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
                        : Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text('Gesynchroniseerd'),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
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
                      final isCreator = widget.uid == widget.createdByUid.trim();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasNoteLive)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'Notitie',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                              subtitle: Text(note),
                            ),
                          if (widget.onManageNote != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: FilledButton.tonalIcon(
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
                                icon: Icon(
                                  hasNoteLive
                                      ? Icons.edit_note
                                      : Icons.note_add_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  hasNoteLive
                                      ? 'Notitie wijzigen'
                                      : 'Notitie toevoegen',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ),
                          if (isCreator)
                            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                              stream: FirebaseFirestore.instance
                                  .doc(
                                    'households/${widget.householdId}/expenses/${widget.expenseId}',
                                  )
                                  .snapshots(),
                              builder: (context, expSnap) {
                                final ed = expSnap.data?.data();
                                final currentTitle =
                                    ((ed?['title'] as String?) ?? widget.title)
                                        .trim();
                                final currentCents =
                                    (ed?['amountCents'] as num?)?.toInt() ??
                                    widget.amountCents;
                                final currentChildIds =
                                    (ed?['childIds'] as List?)
                                        ?.whereType<String>()
                                        .toList() ??
                                    widget.childIds;
                                return Padding(
                                  padding: EdgeInsets.only(
                                    top: widget.onManageNote != null ? 8 : 16,
                                  ),
                                  child: FilledButton.tonalIcon(
                                    onPressed: () => _openEditAmountDialog(
                                      currentAmountCents: currentCents,
                                      currentTitle: currentTitle.isEmpty
                                          ? widget.title
                                          : currentTitle,
                                      currentChildIds: currentChildIds,
                                    ),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      'Uitgave bewerken',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                  ),
                                );
                              },
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

class _PaymentDetailPage extends StatelessWidget {
  const _PaymentDetailPage({
    required this.title,
    required this.amountCents,
    required this.status,
    required this.createdAt,
    this.confirmedAt,
    this.statusExplanation,
  });

  final String title;
  final int amountCents;
  final String status;
  final DateTime? createdAt;
  final DateTime? confirmedAt;
  final String? statusExplanation;

  @override
  Widget build(BuildContext context) {
    final isConfirmed = status == 'confirmed';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
          title: Text(
            'Betaling',
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
                    title: Text(
                      'Beschrijving',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: Text(title),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Bedrag',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                        ),
                      ),
                      subtitle: Text(
                        _ExpenseDetailPage._formatEur(amountCents),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Datum/tijd',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: Text(
                      _ExpenseDetailPage._formatDateTime(createdAt),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Status',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: isConfirmed
                        ? Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text('Bevestigd'),
                            ],
                          )
                        : Row(
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 16,
                                color: onSurface(context, a60),
                              ),
                              const SizedBox(width: 6),
                              const Text('In afwachting'),
                            ],
                          ),
                  ),
                  if (isConfirmed && confirmedAt != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Bevestigd op',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                        ),
                      ),
                      subtitle: Text(
                        _ExpenseDetailPage._formatDateTime(confirmedAt),
                      ),
                    ),
                  if (statusExplanation != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      statusExplanation!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a55),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
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

enum _PeriodFilter { all, custom }

enum _LogboekMode { uitgaven, betalingen, wijzigingen }

enum _PaymentDirection { alle, verzonden, ontvangen }

enum _ExpenseExportFormat { csv, pdf }

class _WijzigRow {
  const _WijzigRow({
    required this.expenseId,
    required this.title,
    required this.fromAmountCents,
    required this.toAmountCents,
    required this.reason,
    required this.editedBy,
    required this.editedAt,
    required this.expenseAmountCents,
    required this.childIds,
    required this.createdBy,
    required this.createdAt,
  });

  final String expenseId;
  final String title;
  final int fromAmountCents;
  final int toAmountCents;
  final String reason;
  final String editedBy;
  final DateTime editedAt;
  final int expenseAmountCents;
  final List<String> childIds;
  final String createdBy;
  final DateTime? createdAt;
}

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

class _LogboekPageState extends State<_LogboekPage>
    with SingleTickerProviderStateMixin {
  static const Duration _logboekHoldMinDuration = Duration(milliseconds: 120);
  static const Duration _logboekHoldFadeDuration = Duration(milliseconds: 180);
  List<_ChildItem> _children = [];
  bool _childrenLoaded = false;
  List<({String uid, String name})> _parentItems = [];
  bool _parentsLoaded = false;
  String? _filterChildId; // null = alle kinderen, anders één kind
  String? _filterParentUid; // null = allebei ouders (geen createdBy-filter)
  _PeriodFilter _periodFilter = _PeriodFilter.all;
  DateTime? _filterStart;
  DateTime? _filterEnd;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _expensesStream;
  _LogboekMode _logboekMode = _LogboekMode.uitgaven;
  _PaymentDirection _paymentDirection = _PaymentDirection.alle;

  /// null = Alle; otherwise filter amount edits by [editedBy] uid.
  String? _wijzigFilterEditedByUid;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _paymentsStream;
  late final TabController _modeTabController;
  bool _initialDataReady = false;
  bool _showInitialHoldOverlay = true;
  bool _initialHoldDismissScheduled = false;
  bool _isOffline = false;
  late final DateTime _initialHoldStartedAt;

  Query<Map<String, dynamic>> _basePeriodQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/expenses',
    );
    if (_periodFilter != _PeriodFilter.all &&
        _filterStart != null &&
        _filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_filterStart!),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(_filterEnd!));
    }
    return q;
  }

  void _rebuildExpensesStream() {
    Query<Map<String, dynamic>> q = _basePeriodQuery();

    if (_filterParentUid != null) {
      q = q.where('createdBy', isEqualTo: _filterParentUid);
    }
    if (_filterChildId != null) {
      q = q.where('childIds', arrayContains: _filterChildId);
    }

    q = q.orderBy('createdAt', descending: true);
    _expensesStream = q.snapshots();
  }

  bool get _uitgavenFiltersActive {
    if (_periodFilter != _PeriodFilter.all) return true;
    if (_filterParentUid != null) return true;
    if (_filterChildId != null) return true;
    return false;
  }

  bool get _logboekFilterIconActive {
    if (_logboekMode == _LogboekMode.uitgaven) {
      return _uitgavenFiltersActive;
    }
    return _periodFilter != _PeriodFilter.all;
  }

  void _rebuildPaymentsStream() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/payments',
    );
    if (_periodFilter != _PeriodFilter.all &&
        _filterStart != null &&
        _filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_filterStart!),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(_filterEnd!));
    }
    q = q.orderBy('createdAt', descending: true);
    _paymentsStream = q.snapshots();
  }

  @override
  void initState() {
    super.initState();
    _initialHoldStartedAt = DateTime.now();
    _modeTabController = TabController(length: 3, vsync: this);
    _rebuildExpensesStream();
    _rebuildPaymentsStream();
    Future.wait([
      _loadChildren(),
      _loadParents(),
      _expensesStream.first,
    ]).then((_) {
      if (!mounted) return;
      setState(() => _initialDataReady = true);
      _dismissInitialHoldOverlayWhenReady();
    }).catchError((error, stackTrace) {
      debugPrint('Logboek initial expenses load error: $error');
    });
    _checkOffline();
  }

  @override
  void dispose() {
    _modeTabController.dispose();
    super.dispose();
  }

  Future<void> _dismissInitialHoldOverlayWhenReady() async {
    if (_initialHoldDismissScheduled || !_showInitialHoldOverlay) return;
    _initialHoldDismissScheduled = true;
    await WidgetsBinding.instance.endOfFrame;
    final elapsed = DateTime.now().difference(_initialHoldStartedAt);
    final remaining = _logboekHoldMinDuration - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
    if (!mounted) return;
    setState(() => _showInitialHoldOverlay = false);
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
      final childrenSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .get();
      final expensesSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/expenses')
          .get();

      final childIdsWithExpense = <String>{};
      for (final d in expensesSnap.docs) {
        final ids =
            (d.data()['childIds'] as List?)?.whereType<String>() ??
            const <String>[];
        childIdsWithExpense.addAll(ids);
      }

      final docs = childrenSnap.docs.toList()
        ..sort((a, b) {
          final aTs = a.data()['createdAt'];
          final bTs = b.data()['createdAt'];
          if (aTs is Timestamp && bTs is Timestamp) {
            return aTs.compareTo(bTs);
          }
          return 0;
        });

      final children = <_ChildItem>[];
      for (final d in docs) {
        final data = d.data();
        final isArchived = data['isArchived'] == true;
        final isDeleted = data['isDeleted'] == true;
        final active = !isArchived && !isDeleted;
        final hasExpense = childIdsWithExpense.contains(d.id);
        if (active || ((isArchived || isDeleted) && hasExpense)) {
          children.add(
            _ChildItem(
              id: d.id,
              name: (data['name'] as String?)?.trim() ?? '?',
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _children = children;
          _childrenLoaded = true;
          if (_filterChildId != null &&
              !_children.any((c) => c.id == _filterChildId)) {
            _filterChildId = null;
            _rebuildExpensesStream();
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _childrenLoaded = true);
    }
  }

  Future<void> _loadParents() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/members')
          .limit(2)
          .get();
      final uids = snap.docs.map((d) => d.id).toList();
      // Current user first, then others.
      final sorted = [
        if (uids.contains(widget.uid)) widget.uid,
        ...uids.where((id) => id != widget.uid),
      ];
      final items = [
        for (final uid in sorted)
          (
            uid: uid,
            name: uid == widget.uid
                ? (widget.myName ?? 'Jij')
                : (widget.otherName ?? 'Co-parent'),
          ),
      ];
      if (mounted) {
        setState(() {
          _parentItems = items;
          _parentsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _parentsLoaded = true);
    }
  }

  void _showPeriodFilterSheet() {
    final pageContext = context;
    final now = DateTime.now();

    void selectPeriod(_PeriodFilter filter, DateTime? start, DateTime? end) {
      setState(() {
        _periodFilter = filter;
        _filterStart = start;
        _filterEnd = end;
        _rebuildExpensesStream();
        _rebuildPaymentsStream();
      });
      Navigator.of(context).pop();
    }

    final options = [
      ('Alle tijd', _PeriodFilter.all, null, null),
      ('Periode kiezen', _PeriodFilter.custom, null, null),
    ];

    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Text(
                  'Periode',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final (label, filter, start, end) in options)
                ListTile(
                  title: Text(label),
                  leading: _periodFilter == filter
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    if (filter == _PeriodFilter.custom) {
                      Navigator.of(context).pop();
                      final initialRange =
                          (_periodFilter == _PeriodFilter.custom &&
                              _filterStart != null &&
                              _filterEnd != null)
                          ? DateTimeRange(
                              start: _filterStart!,
                              end: _filterEnd!.subtract(
                                const Duration(days: 1),
                              ),
                            )
                          : DateTimeRange(
                              start: now.subtract(const Duration(days: 29)),
                              end: now,
                            );
                      final range = await showDateRangePicker(
                        context: pageContext,
                        initialDateRange: initialRange,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(now.year, now.month, now.day),
                      );
                      if (range == null || !mounted) return;
                      setState(() {
                        _periodFilter = _PeriodFilter.custom;
                        _filterStart = DateTime(
                          range.start.year,
                          range.start.month,
                          range.start.day,
                        );
                        _filterEnd = DateTime(
                          range.end.year,
                          range.end.month,
                          range.end.day + 1,
                        );
                        _rebuildExpensesStream();
                        _rebuildPaymentsStream();
                      });
                      return;
                    }
                    selectPeriod(filter, start, end);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showUitgavenFilterSheet() {
    final pageContext = context;
    final now = DateTime.now();

    Future<void> pickCustomPeriod(StateSetter setModalState) async {
      final initialRange =
          (_periodFilter == _PeriodFilter.custom &&
              _filterStart != null &&
              _filterEnd != null)
          ? DateTimeRange(
              start: _filterStart!,
              end: _filterEnd!.subtract(const Duration(days: 1)),
            )
          : DateTimeRange(
              start: now.subtract(const Duration(days: 29)),
              end: now,
            );
      final range = await showDateRangePicker(
        context: pageContext,
        initialDateRange: initialRange,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month, now.day),
      );
      if (range == null || !mounted) return;
      setState(() {
        _periodFilter = _PeriodFilter.custom;
        _filterStart = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        _filterEnd = DateTime(
          range.end.year,
          range.end.month,
          range.end.day + 1,
        );
        _rebuildExpensesStream();
        _rebuildPaymentsStream();
      });
      setModalState(() {});
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = min(
          480.0,
          MediaQuery.of(sheetContext).size.height * 0.65,
        );
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'Filter',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _filterParentUid = null;
                                  _filterChildId = null;
                                  _periodFilter = _PeriodFilter.all;
                                  _filterStart = null;
                                  _filterEnd = null;
                                  _rebuildExpensesStream();
                                  _rebuildPaymentsStream();
                                });
                                setModalState(() {});
                              },
                              child: const Text('Alle filters wissen'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_parentsLoaded && _parentItems.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Ouder',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Allebei'),
                                selected: _filterParentUid == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _filterParentUid = null;
                                    _rebuildExpensesStream();
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final p in _parentItems)
                                FilterChip(
                                  label: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  selected: _filterParentUid == p.uid,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _filterParentUid = v ? p.uid : null;
                                      _rebuildExpensesStream();
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_childrenLoaded && _children.length > 1) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Kind',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Alle'),
                                selected: _filterChildId == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _filterChildId = null;
                                    _rebuildExpensesStream();
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final c in _children)
                                FilterChip(
                                  label: Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  selected: _filterChildId == c.id,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _filterChildId = v ? c.id : null;
                                      _rebuildExpensesStream();
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Periode',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: onSurface(context, a60)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_expenseExportPeriodLabel()),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => pickCustomPeriod(setModalState),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  static String _fmtDateWithYear(DateTime? dt) {
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

  static String _fmtEur(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
  }

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
    return '${dt.day} ${mo[dt.month - 1]}';
  }

  String? _otherParentUid() {
    for (final p in _parentItems) {
      if (p.uid != widget.uid) return p.uid;
    }
    return null;
  }

  String _expenseExportParentLabel() {
    if (_filterParentUid == null) return 'Allebei';
    for (final parent in _parentItems) {
      if (parent.uid == _filterParentUid) return parent.name;
    }
    return 'Allebei';
  }

  String _expenseExportChildLabel() {
    if (_filterChildId == null) return 'Alle';
    for (final child in _children) {
      if (child.id == _filterChildId) return child.name;
    }
    return 'Alle';
  }

  String _expenseExportPeriodLabel() {
    if (_periodFilter == _PeriodFilter.custom &&
        _filterStart != null &&
        _filterEnd != null) {
      final inclusiveEnd = _filterEnd!.subtract(const Duration(days: 1));
      if (_filterStart!.year == inclusiveEnd.year &&
          _filterStart!.month == inclusiveEnd.month &&
          _filterStart!.day == inclusiveEnd.day) {
        return _fmtDateWithYear(_filterStart);
      }
      return '${_fmtDateWithYear(_filterStart)} t/m ${_fmtDateWithYear(inclusiveEnd)}';
    }
    return 'Alle tijd';
  }

  List<({String label, String value})> _expenseExportSummaryRows() => [
    (label: 'Ouder', value: _expenseExportParentLabel()),
    (label: 'Kind', value: _expenseExportChildLabel()),
    (label: 'Periode', value: _expenseExportPeriodLabel()),
  ];

  String _paymentExportDirectionLabel() => switch (_paymentDirection) {
    _PaymentDirection.alle => 'Alle',
    _PaymentDirection.verzonden => 'Verzonden',
    _PaymentDirection.ontvangen => 'Ontvangen',
  };

  List<({String label, String value})> _paymentExportSummaryRows() => [
    (label: 'Richting', value: _paymentExportDirectionLabel()),
    (label: 'Periode', value: _expenseExportPeriodLabel()),
  ];

  String _wijzigExportEditedByLabel() {
    if (_wijzigFilterEditedByUid == null) return 'Alle';
    if (_wijzigFilterEditedByUid == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  List<({String label, String value})> _wijzigExportSummaryRows() => [
    (label: 'Gewijzigd door', value: _wijzigExportEditedByLabel()),
    (label: 'Periode', value: _expenseExportPeriodLabel()),
  ];

  static String _csvEscape(String value) =>
      '"${value.replaceAll('"', '""')}"';

  static String _csvLine(List<String> values) =>
      values.map(_csvEscape).join(';');

  static String _fmtCsvAmount(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    return '${negative ? '-' : ''}$euros,${rem.toString().padLeft(2, '0')}';
  }

  Query<Map<String, dynamic>> _buildFrozenExpenseExportQuery({
    required String? filterChildId,
    required String? filterParentUid,
    required _PeriodFilter periodFilter,
    required DateTime? filterStart,
    required DateTime? filterEnd,
  }) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/expenses',
    );
    if (periodFilter != _PeriodFilter.all &&
        filterStart != null &&
        filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(filterStart),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(filterEnd));
    }
    if (filterParentUid != null) {
      q = q.where('createdBy', isEqualTo: filterParentUid);
    }
    if (filterChildId != null) {
      q = q.where('childIds', arrayContains: filterChildId);
    }
    return q.orderBy('createdAt', descending: true);
  }

  Query<Map<String, dynamic>> _buildFrozenPaymentExportQuery({
    required _PeriodFilter periodFilter,
    required DateTime? filterStart,
    required DateTime? filterEnd,
  }) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/payments',
    );
    if (periodFilter != _PeriodFilter.all &&
        filterStart != null &&
        filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(filterStart),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(filterEnd));
    }
    return q.orderBy('createdAt', descending: true);
  }

  String _expenseExportPaidByName(
    String createdBy,
    Map<String, String> parentNamesByUid,
  ) {
    final direct = parentNamesByUid[createdBy]?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    if (createdBy == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  List<String> _expenseExportChildNames(
    List<String> childIds,
    Map<String, String> childNamesById,
  ) {
    return childIds.map((id) => childNamesById[id] ?? 'Verwijderd kind').toList();
  }

  int _expenseExportDisplayCents(int amountCents, List<String> childIds) {
    final nKids = childIds.length;
    final isFiltered = _filterChildId != null && nKids > 0;
    return isFiltered ? (amountCents / nKids).round() : amountCents;
  }

  String _expenseExportFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'uitgaven-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  }

  String _expenseExportPdfFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'uitgaven-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.pdf';
  }

  String _paymentExportFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'betalingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  }

  String _paymentExportPdfFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'betalingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.pdf';
  }

  String _wijzigingenExportFilename(String extension) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'wijzigingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.$extension';
  }

  String _paymentPartyName(String uid) {
    final trimmedUid = uid.trim();
    if (trimmedUid == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  String _wijzigEditedByName(String uid) {
    final trimmedUid = uid.trim();
    if (trimmedUid == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  Future<List<({
    DateTime? createdAt,
    String title,
    int displayCents,
    String paidByName,
    String childrenLabel,
  })>> _loadExpenseExportRows() async {
    final filterChildId = _filterChildId;
    final filterParentUid = _filterParentUid;
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;
    final childNamesById = <String, String>{
      for (final child in _children) child.id: child.name,
    };
    final parentNamesByUid = <String, String>{
      for (final parent in _parentItems) parent.uid: parent.name,
    };

    final query = _buildFrozenExpenseExportQuery(
      filterChildId: filterChildId,
      filterParentUid: filterParentUid,
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
    );
    final snap = await query.get();
    return snap.docs.map((doc) {
      final data = doc.data();
      final title = (data['title'] as String?)?.trim() ?? '(zonder naam)';
      final amountCents = (data['amountCents'] as num?)?.toInt() ?? 0;
      final childIds =
          (data['childIds'] as List?)?.whereType<String>().toList() ??
          const <String>[];
      final createdBy = (data['createdBy'] as String?)?.trim() ?? '';
      final createdAtRaw = data['createdAt'];
      DateTime? createdAt;
      if (createdAtRaw is Timestamp) {
        createdAt = createdAtRaw.toDate().toLocal();
      } else if (createdAtRaw is DateTime) {
        createdAt = createdAtRaw.toLocal();
      }

      final displayCents = _expenseExportDisplayCents(amountCents, childIds);
      final paidByName = _expenseExportPaidByName(createdBy, parentNamesByUid);
      final childNames = _expenseExportChildNames(childIds, childNamesById);

      return (
        createdAt: createdAt,
        title: title,
        displayCents: displayCents,
        paidByName: paidByName,
        childrenLabel: childNames.join(' | '),
      );
    }).toList(growable: false);
  }

  Future<void> _exportExpensesCsv() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadExpenseExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen uitgaven gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      final csv = StringBuffer()
        ..writeln(
          _csvLine(const ['Datum', 'Titel', 'Bedrag', 'Betaald door', 'Kinderen']),
        );

      for (final row in rows) {
        csv.writeln(
          _csvLine([
            _fmtDateWithYear(row.createdAt),
            row.title,
            _fmtCsvAmount(row.displayCents),
            row.paidByName,
            row.childrenLabel,
          ]),
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_expenseExportFilename()}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Uitgaven export',
        text: 'Uitgaven uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'CSV-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportExpensesPdf() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadExpenseExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen uitgaven gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final summaryRows = [
        (label: 'Tab', value: 'Uitgaven'),
        (label: 'Ouder', value: _expenseExportParentLabel()),
        (label: 'Kind', value: _expenseExportChildLabel()),
        (label: 'Periode', value: _expenseExportPeriodLabel()),
      ];

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Uitgaven',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                2: pw.Alignment.centerRight,
              },
              columnWidths: {
                0: const pw.FixedColumnWidth(64),
                1: const pw.FlexColumnWidth(2.2),
                2: const pw.FixedColumnWidth(64),
                3: const pw.FixedColumnWidth(86),
                4: const pw.FlexColumnWidth(1.8),
              },
              headers: const [
                'Datum',
                'Titel',
                'Bedrag',
                'Betaald door',
                'Kinderen',
              ],
              data: rows
                  .map(
                    (row) => [
                      _fmtDateWithYear(row.createdAt),
                      row.title,
                      _fmtCsvAmount(row.displayCents),
                      row.paidByName,
                      row.childrenLabel,
                    ],
                  )
                  .toList(growable: false),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_expenseExportPdfFilename()}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Uitgaven export',
        text: 'Uitgaven uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'PDF-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportPaymentsCsv() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final rows = await _loadPaymentExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen betalingen gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      final csv = StringBuffer()
        ..writeln(
          _csvLine(const ['Datum', 'Bedrag', 'Van', 'Naar', 'Status']),
        );

      for (final row in rows) {
        csv.writeln(
          _csvLine([
            _fmtDateWithYear(row.createdAt),
            _fmtCsvAmount(row.amountCents),
            row.fromName,
            row.toName,
            row.statusLabel,
          ]),
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_paymentExportFilename()}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Betalingen export',
        text: 'Betalingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'CSV-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<List<({
    DateTime? createdAt,
    int amountCents,
    String fromName,
    String toName,
    String statusLabel,
  })>> _loadPaymentExportRows() async {
    final paymentDirection = _paymentDirection;
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;

    final query = _buildFrozenPaymentExportQuery(
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
    );
    final snap = await query.get();
    final allDocs = snap.docs;
    final docs = switch (paymentDirection) {
      _PaymentDirection.alle => allDocs,
      _PaymentDirection.verzonden =>
        allDocs
            .where(
              (d) => (d.data()['fromUserId'] as String?)?.trim() == widget.uid,
            )
            .toList(),
      _PaymentDirection.ontvangen =>
        allDocs
            .where(
              (d) => (d.data()['toUserId'] as String?)?.trim() == widget.uid,
            )
            .toList(),
    };

    return docs.map((doc) {
      final data = doc.data();
      final amountCents = (data['amountCents'] as num?)?.toInt() ?? 0;
      final fromUserId = (data['fromUserId'] as String?)?.trim() ?? '';
      final toUserId = (data['toUserId'] as String?)?.trim() ?? '';
      final status = (data['status'] as String?)?.trim() ?? '';
      final createdAtRaw = data['createdAt'];
      DateTime? createdAt;
      if (createdAtRaw is Timestamp) {
        createdAt = createdAtRaw.toDate().toLocal();
      } else if (createdAtRaw is DateTime) {
        createdAt = createdAtRaw.toLocal();
      }
      return (
        createdAt: createdAt,
        amountCents: amountCents,
        fromName: _paymentPartyName(fromUserId),
        toName: _paymentPartyName(toUserId),
        statusLabel: status == 'confirmed' ? 'Bevestigd' : 'In afwachting',
      );
    }).toList(growable: false);
  }

  Future<void> _exportPaymentsPdf() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadPaymentExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen betalingen gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      String pdfPeriodLabel() {
        final dates = rows
            .map((row) => row.createdAt)
            .whereType<DateTime>()
            .toList(growable: false);
        if (dates.isEmpty) return '-';
        dates.sort();
        final start = _fmtDateWithYear(dates.first);
        final end = _fmtDateWithYear(dates.last);
        return start == end ? start : '$start - $end';
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final summaryRows = [
        (label: 'Tab', value: 'Betalingen'),
        (label: 'Richting', value: _paymentExportDirectionLabel()),
        (label: 'Periode', value: pdfPeriodLabel()),
      ];

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Betalingen',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                1: pw.Alignment.centerRight,
              },
              columnWidths: {
                0: const pw.FixedColumnWidth(64),
                1: const pw.FixedColumnWidth(64),
                2: const pw.FixedColumnWidth(92),
                3: const pw.FixedColumnWidth(92),
                4: const pw.FlexColumnWidth(1.2),
              },
              headers: const [
                'Datum',
                'Bedrag',
                'Van',
                'Naar',
                'Status',
              ],
              data: rows
                  .map(
                    (row) => [
                      _fmtDateWithYear(row.createdAt),
                      _fmtCsvAmount(row.amountCents),
                      row.fromName,
                      row.toName,
                      row.statusLabel,
                    ],
                  )
                  .toList(growable: false),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_paymentExportPdfFilename()}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Betalingen export',
        text: 'Betalingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'CSV-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportWijzigingenCsv() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadWijzigingenExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen bedragwijzigingen gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      final csv = StringBuffer()
        ..writeln(
          _csvLine(
            const [
              'Datum wijziging',
              'Titel uitgave',
              'Van bedrag',
              'Naar bedrag',
              'Reden',
              'Gewijzigd door',
            ],
          ),
        );

      for (final row in rows) {
        csv.writeln(
          _csvLine([
            _ExpenseDetailPage._formatDateTime(row.editedAt),
            row.title,
            _fmtCsvAmount(row.fromAmountCents),
            _fmtCsvAmount(row.toAmountCents),
            row.reason,
            _wijzigEditedByName(row.editedBy),
          ]),
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_wijzigingenExportFilename('csv')}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Wijzigingen export',
        text: 'Wijzigingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'CSV-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<List<_WijzigRow>> _loadWijzigingenExportRows() async {
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;
    final editedByUid = _wijzigFilterEditedByUid;

    final snap = await FirebaseFirestore.instance
        .collection('households/${widget.householdId}/expenses')
        .get();
    return _loadWijzigRows(
      snap.docs,
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
      editedByUid: editedByUid,
    );
  }

  Future<void> _exportWijzigingenPdf() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadWijzigingenExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Geen bedragwijzigingen gevonden voor deze selectie.'),
          ),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      String pdfPeriodLabel() {
        final dates = rows.map((row) => row.editedAt).toList(growable: false);
        if (dates.isEmpty) return '-';
        dates.sort();
        final start = _fmtDateWithYear(dates.first);
        final end = _fmtDateWithYear(dates.last);
        return start == end ? start : '$start - $end';
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final summaryRows = [
        (label: 'Tab', value: 'Wijzigingen'),
        (label: 'Gewijzigd door', value: _wijzigExportEditedByLabel()),
        (label: 'Periode', value: pdfPeriodLabel()),
      ];

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Wijzigingen',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
              columnWidths: {
                0: const pw.FixedColumnWidth(74),
                1: const pw.FlexColumnWidth(1.8),
                2: const pw.FixedColumnWidth(58),
                3: const pw.FixedColumnWidth(58),
                4: const pw.FlexColumnWidth(1.7),
                5: const pw.FixedColumnWidth(78),
              },
              headers: const [
                'Datum wijziging',
                'Titel uitgave',
                'Van bedrag',
                'Naar bedrag',
                'Reden',
                'Gewijzigd door',
              ],
              data: rows
                  .map(
                    (row) => [
                      _ExpenseDetailPage._formatDateTime(row.editedAt)
                          .replaceAll(' • ', ' - '),
                      row.title,
                      _fmtCsvAmount(row.fromAmountCents),
                      _fmtCsvAmount(row.toAmountCents),
                      row.reason,
                      _wijzigEditedByName(row.editedBy),
                    ],
                  )
                  .toList(growable: false),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_wijzigingenExportFilename('pdf')}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Wijzigingen export',
        text: 'Wijzigingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'PDF-export mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Widget _buildExportSummaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: onSurface(context, a60)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: onSurface(context, a84),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showExpenseExportConfirmSheet() {
    final summaryRows = _expenseExportSummaryRows();
    var selectedFormat = _ExpenseExportFormat.pdf;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 8,
              bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Exporteer selectie',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kies een formaat voor de huidige selectie.',
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: onSurface(sheetContext, a68),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                for (final row in summaryRows)
                  _buildExportSummaryRow(row.label, row.value),
                const SizedBox(height: 4),
                Text(
                  'Formaat',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: onSurface(sheetContext, a60),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('PDF'),
                      selected: selectedFormat == _ExpenseExportFormat.pdf,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.pdf,
                      ),
                    ),
                    FilterChip(
                      label: const Text('CSV'),
                      selected: selectedFormat == _ExpenseExportFormat.csv,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.csv,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    if (selectedFormat == _ExpenseExportFormat.pdf) {
                      await _exportExpensesPdf();
                      return;
                    }
                    await _exportExpensesCsv();
                  },
                  child: Text(
                    selectedFormat == _ExpenseExportFormat.pdf
                        ? 'Exporteer PDF'
                        : 'Exporteer CSV',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPaymentExportConfirmSheet() {
    final summaryRows = _paymentExportSummaryRows();
    var selectedFormat = _ExpenseExportFormat.pdf;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 8,
              bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Exporteer selectie',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kies een formaat voor de huidige selectie.',
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: onSurface(sheetContext, a68),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                for (final row in summaryRows)
                  _buildExportSummaryRow(row.label, row.value),
                const SizedBox(height: 4),
                Text(
                  'Formaat',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: onSurface(sheetContext, a60),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('PDF'),
                      selected: selectedFormat == _ExpenseExportFormat.pdf,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.pdf,
                      ),
                    ),
                    FilterChip(
                      label: const Text('CSV'),
                      selected: selectedFormat == _ExpenseExportFormat.csv,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.csv,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    if (selectedFormat == _ExpenseExportFormat.pdf) {
                      await _exportPaymentsPdf();
                      return;
                    }
                    await _exportPaymentsCsv();
                  },
                  child: Text(
                    selectedFormat == _ExpenseExportFormat.pdf
                        ? 'Exporteer PDF'
                        : 'Exporteer CSV',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showWijzigingenExportConfirmSheet() {
    final summaryRows = _wijzigExportSummaryRows();
    var selectedFormat = _ExpenseExportFormat.pdf;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 8,
              bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Exporteer selectie',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kies een formaat voor de huidige selectie.',
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: onSurface(sheetContext, a68),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                for (final row in summaryRows)
                  _buildExportSummaryRow(row.label, row.value),
                const SizedBox(height: 4),
                Text(
                  'Formaat',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: onSurface(sheetContext, a60),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('PDF'),
                      selected: selectedFormat == _ExpenseExportFormat.pdf,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.pdf,
                      ),
                    ),
                    FilterChip(
                      label: const Text('CSV'),
                      selected: selectedFormat == _ExpenseExportFormat.csv,
                      showCheckmark: false,
                      onSelected: (_) => setModalState(
                        () => selectedFormat = _ExpenseExportFormat.csv,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    if (selectedFormat == _ExpenseExportFormat.pdf) {
                      await _exportWijzigingenPdf();
                      return;
                    }
                    await _exportWijzigingenCsv();
                  },
                  child: Text(
                    selectedFormat == _ExpenseExportFormat.pdf
                        ? 'Exporteer PDF'
                        : 'Exporteer CSV',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<List<_WijzigRow>> _loadWijzigRows(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs,
    {
      _PeriodFilter? periodFilter,
      DateTime? filterStart,
      DateTime? filterEnd,
      String? editedByUid,
    }
  ) async {
    final effectivePeriodFilter = periodFilter ?? _periodFilter;
    final effectiveFilterStart = filterStart ?? _filterStart;
    final effectiveFilterEnd = filterEnd ?? _filterEnd;
    final effectiveEditedByUid = editedByUid ?? _wijzigFilterEditedByUid;
    final rows = <_WijzigRow>[];
    await Future.wait(
      expenseDocs.map((d) async {
        final e = d.data();
        final title = (e['title'] as String?)?.trim() ?? '(zonder naam)';
        final amountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
        final childIds =
            (e['childIds'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final createdBy = (e['createdBy'] as String?)?.trim() ?? '';
        final createdAtRaw = e['createdAt'];
        DateTime? createdAt;
        if (createdAtRaw is Timestamp) {
          createdAt = createdAtRaw.toDate().toLocal();
        } else if (createdAtRaw is DateTime) {
          createdAt = createdAtRaw.toLocal();
        }
        final sub = await FirebaseFirestore.instance
            .collection(
              'households/${widget.householdId}/expenses/${d.id}/amountEdits',
            )
            .get();
        for (final ed in sub.docs) {
          final h = ed.data();
          final fromC = (h['fromAmountCents'] as num?)?.toInt() ?? 0;
          final toC = (h['toAmountCents'] as num?)?.toInt() ?? 0;
          final reason = (h['reason'] as String?)?.trim() ?? '';
          final editedBy = (h['editedBy'] as String?)?.trim() ?? '';
          final editedAtRaw = h['editedAt'];
          DateTime? editedAtDt;
          if (editedAtRaw is Timestamp) {
            editedAtDt = editedAtRaw.toDate().toLocal();
          } else if (editedAtRaw is DateTime) {
            editedAtDt = editedAtRaw.toLocal();
          }
          if (editedAtDt == null) continue;
          if (effectivePeriodFilter != _PeriodFilter.all &&
              effectiveFilterStart != null &&
              effectiveFilterEnd != null) {
            final ed = editedAtDt;
            if (ed.isBefore(effectiveFilterStart) ||
                !ed.isBefore(effectiveFilterEnd)) {
              continue;
            }
          }
          rows.add(
            _WijzigRow(
              expenseId: d.id,
              title: title,
              fromAmountCents: fromC,
              toAmountCents: toC,
              reason: reason,
              editedBy: editedBy,
              editedAt: editedAtDt,
              expenseAmountCents: amountCents,
              childIds: childIds,
              createdBy: createdBy,
              createdAt: createdAt,
            ),
          );
        }
      }),
    );
    rows.sort((a, b) => b.editedAt.compareTo(a.editedAt));
    if (effectiveEditedByUid != null) {
      rows.removeWhere((r) => r.editedBy != effectiveEditedByUid);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final activeTabIndex = _logboekMode.index;
    final logboekContent = !_initialDataReady
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isOffline)
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
              if (_logboekMode == _LogboekMode.wijzigingen)
                _buildWijzigingenEditorFilterRow(context),
              Expanded(
                child: IndexedStack(
                  index: activeTabIndex,
                  children: [
                    _buildExpenseList(context),
                    _buildPaymentList(context),
                    _buildWijzigingenList(context),
                  ],
                ),
              ),
            ],
          );
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
      actions: [
        IconButton(
          icon: Icon(
            _logboekFilterIconActive
                ? Icons.filter_alt
                : Icons.filter_list_outlined,
          ),
          color: _logboekFilterIconActive
              ? Theme.of(context).colorScheme.primary
              : null,
          onPressed: () {
            if (_logboekMode == _LogboekMode.uitgaven) {
              _showUitgavenFilterSheet();
              return;
            }
            _showPeriodFilterSheet();
          },
          tooltip: 'Filter',
        ),
        if (_logboekMode == _LogboekMode.uitgaven ||
            _logboekMode == _LogboekMode.betalingen ||
            _logboekMode == _LogboekMode.wijzigingen)
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () {
              if (_logboekMode == _LogboekMode.betalingen) {
                _showPaymentExportConfirmSheet();
                return;
              }
              if (_logboekMode == _LogboekMode.wijzigingen) {
                _showWijzigingenExportConfirmSheet();
                return;
              }
              _showExpenseExportConfirmSheet();
            },
            tooltip: 'Exporteer selectie',
          ),
      ],
      bottom: TabBar(
        controller: _modeTabController,
        onTap: (i) => setState(() {
          _logboekMode = _LogboekMode.values[i];
        }),
        tabs: const [
          Tab(text: 'Uitgaven'),
          Tab(text: 'Betalingen'),
          Tab(text: 'Wijzigingen'),
        ],
        isScrollable: true,
        tabAlignment: TabAlignment.center,
        indicatorSize: TabBarIndicatorSize.label,
        dividerHeight: 0.5,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: appBar,
        body: Stack(
          fit: StackFit.expand,
          children: [
            logboekContent,
            IgnorePointer(
              ignoring: !_showInitialHoldOverlay,
              child: AnimatedOpacity(
                opacity: _showInitialHoldOverlay ? 1 : 0,
                duration: _logboekHoldFadeDuration,
                curve: Curves.easeOut,
                child: const ColoredBox(color: Color(0xFFF7F6F4)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWijzigingenEditorFilterRow(BuildContext context) {
    final myLabel = widget.myName ?? 'Jij';
    final otherUid = _otherParentUid();
    final otherLabel = widget.otherName ?? 'Co-parent';
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 4, bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilterChip(
              label: const Text('Alle'),
              selected: _wijzigFilterEditedByUid == null,
              showCheckmark: false,
              onSelected: (_) => setState(() {
                _wijzigFilterEditedByUid = null;
              }),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text(myLabel),
              selected: _wijzigFilterEditedByUid == widget.uid,
              showCheckmark: false,
              onSelected: (v) => setState(() {
                _wijzigFilterEditedByUid = v ? widget.uid : null;
              }),
            ),
            if (otherUid != null) ...[
              const SizedBox(width: 8),
              FilterChip(
                label: Text(otherLabel),
                selected: _wijzigFilterEditedByUid == otherUid,
                showCheckmark: false,
                onSelected: (v) => setState(() {
                  _wijzigFilterEditedByUid = v ? otherUid : null;
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWijzigingenList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('households/${widget.householdId}/expenses')
          .snapshots(),
      builder: (context, expSnap) {
        if (expSnap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mapUserFacingError(expSnap.error!)),
            ),
          );
        }
        if (!expSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = expSnap.data!.docs;
        final sig = docs
            .map(
              (d) =>
                  '${d.id}:${(d.data()['amountCents'] as num?)?.toInt() ?? 0}',
            )
            .join('|');
        return FutureBuilder<List<_WijzigRow>>(
          key: ValueKey(
            '${_periodFilter}_${_filterStart}_${_filterEnd}_${_wijzigFilterEditedByUid}_$sig',
          ),
          future: _loadWijzigRows(docs),
          builder: (context, futSnap) {
            if (futSnap.connectionState == ConnectionState.waiting &&
                !futSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (futSnap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(mapUserFacingError(futSnap.error!)),
                ),
              );
            }
            final rows = futSnap.data ?? const <_WijzigRow>[];
            if (rows.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Geen bedragwijzigingen gevonden.'),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: rows.length,
              separatorBuilder: (context, _) => Divider(
                height: 1,
                thickness: 0.4,
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
              itemBuilder: (context, i) {
                final row = rows[i];
                final whoLabel = row.editedBy == widget.uid
                    ? 'Jij'
                    : (widget.otherName ?? 'Co-parent');
                final paidByName = row.createdBy == widget.uid
                    ? (widget.myName ?? 'Jij')
                    : (widget.otherName ?? 'Co-parent');
                return Material(
                  type: MaterialType.transparency,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    highlightColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.10),
                    splashColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.08),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _ExpenseDetailPage(
                          householdId: widget.householdId,
                          expenseId: row.expenseId,
                          uid: widget.uid,
                          createdByUid: row.createdBy,
                          title: row.title,
                          amountCents: row.expenseAmountCents,
                          paidByName: paidByName,
                          createdAt: row.createdAt,
                          isPending: false,
                          onManageNote: row.createdBy == widget.uid
                              ? () => _doManagePrivateNote(
                                  context,
                                  householdId: widget.householdId,
                                  expenseId: row.expenseId,
                                  uid: widget.uid,
                                )
                              : null,
                          otherParentName: widget.otherName,
                          childIds: row.childIds,
                          childNames: row.childIds
                              .map(
                                (id) =>
                                    _children
                                        .where((c) => c.id == id)
                                        .map((c) => c.name)
                                        .firstOrNull ??
                                    'Verwijderd kind',
                              )
                              .toList(),
                        ),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 4,
                      ),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(
                        row.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_fmtEur(row.fromAmountCents)} → ${_fmtEur(row.toAmountCents)}',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$whoLabel · ${_ExpenseDetailPage._formatDateTime(row.editedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: onSurface(context, a55)),
                            ),
                            if (row.reason.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                row.reason,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: onSurface(context, a68),
                                      height: 1.35,
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
            );
          },
        );
      },
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
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Geen uitgaven gevonden.'),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (context, _) => Divider(
            height: 1,
            thickness: 0.4,
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
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
                ? '$dateStr · aandeel 1/$nKids'
                : nKids > 0
                ? '$dateStr · ${nKids == 1 ? '1 kind' : '$nKids kinderen'}'
                : dateStr;
            return Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                highlightColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.10),
                splashColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.08),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _ExpenseDetailPage(
                      householdId: widget.householdId,
                      expenseId: d.id,
                      uid: widget.uid,
                      createdByUid: createdBy,
                      title: title,
                      amountCents: amountCents,
                      paidByName: paidByName,
                      createdAt: createdAt,
                      isPending: false,
                      onManageNote: createdBy == widget.uid
                          ? () => _doManagePrivateNote(
                              context,
                              householdId: widget.householdId,
                              expenseId: d.id,
                              uid: widget.uid,
                            )
                          : null,
                      otherParentName: widget.otherName,
                      childIds: childIds,
                      childNames: childIds
                          .map(
                            (id) =>
                                _children
                                    .where((c) => c.id == id)
                                    .map((c) => c.name)
                                    .firstOrNull ??
                                'Verwijderd kind',
                          )
                          .toList(),
                    ),
                  ),
                ),
                child: ListTile(
                  key: ValueKey(d.id),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitleStr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a55),
                      ),
                    ),
                  ),
                  trailing: Text(
                    _fmtEur(displayCents),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPaymentFilterRow(
    BuildContext context,
    int allCount,
    int sentCount,
    int receivedCount,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(left: 21, right: 16, top: 8, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilterChip(
              label: Text('Alle ($allCount)'),
              selected: _paymentDirection == _PaymentDirection.alle,
              showCheckmark: false,
              onSelected: (_) => setState(() {
                _paymentDirection = _PaymentDirection.alle;
              }),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text('Verzonden ($sentCount)'),
              selected: _paymentDirection == _PaymentDirection.verzonden,
              showCheckmark: false,
              onSelected: (v) => setState(() {
                _paymentDirection = v
                    ? _PaymentDirection.verzonden
                    : _PaymentDirection.alle;
              }),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text('Ontvangen ($receivedCount)'),
              selected: _paymentDirection == _PaymentDirection.ontvangen,
              showCheckmark: false,
              onSelected: (v) => setState(() {
                _paymentDirection = v
                    ? _PaymentDirection.ontvangen
                    : _PaymentDirection.alle;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _paymentsStream,
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
        if (allDocs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Geen betalingen gevonden.'),
            ),
          );
        }

        final sentCount = allDocs
            .where(
              (d) => (d.data()['fromUserId'] as String?)?.trim() == widget.uid,
            )
            .length;
        final receivedCount = allDocs
            .where(
              (d) => (d.data()['toUserId'] as String?)?.trim() == widget.uid,
            )
            .length;

        final docs = switch (_paymentDirection) {
          _PaymentDirection.alle => allDocs,
          _PaymentDirection.verzonden =>
            allDocs
                .where(
                  (d) =>
                      (d.data()['fromUserId'] as String?)?.trim() == widget.uid,
                )
                .toList(),
          _PaymentDirection.ontvangen =>
            allDocs
                .where(
                  (d) =>
                      (d.data()['toUserId'] as String?)?.trim() == widget.uid,
                )
                .toList(),
        };

        final Widget listWidget;
        if (docs.isEmpty) {
          listWidget = const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Geen betalingen gevonden.'),
            ),
          );
        } else {
          listWidget = ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: docs.length,
            separatorBuilder: (context, _) => Divider(
              height: 1,
              thickness: 0.4,
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
            itemBuilder: (context, i) {
              final d = docs[i];
              final p = d.data();
              final amountCents = (p['amountCents'] as num?)?.toInt() ?? 0;
              final fromUserId = (p['fromUserId'] as String?)?.trim() ?? '';
              final status = (p['status'] as String?)?.trim() ?? '';
              final createdAtRaw = p['createdAt'];
              DateTime? createdAt;
              if (createdAtRaw is Timestamp) {
                createdAt = createdAtRaw.toDate().toLocal();
              } else if (createdAtRaw is DateTime) {
                createdAt = createdAtRaw.toLocal();
              }

              final bool isSender = fromUserId == widget.uid;
              final String otherName = widget.otherName ?? 'Co-parent';
              final String title = isSender
                  ? 'Betaling aan $otherName'
                  : 'Betaling van $otherName';
              final String statusStr = status == 'confirmed'
                  ? 'Bevestigd'
                  : 'In afwachting';
              final String dateStr = _fmtDate(createdAt);
              final String subtitleStr = '$dateStr · $statusStr';
              final bool isPending = status != 'confirmed';

              final confirmedAtRaw = p['confirmedAt'];
              DateTime? confirmedAt;
              if (confirmedAtRaw is Timestamp) {
                confirmedAt = confirmedAtRaw.toDate().toLocal();
              } else if (confirmedAtRaw is DateTime) {
                confirmedAt = confirmedAtRaw.toLocal();
              }

              final String? statusExplanation = isPending
                  ? (isSender
                        ? 'Wacht op bevestiging door $otherName'
                        : 'Wacht op jouw bevestiging')
                  : null;

              return Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  highlightColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.10),
                  splashColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _PaymentDetailPage(
                        title: title,
                        amountCents: amountCents,
                        status: status,
                        createdAt: createdAt,
                        confirmedAt: confirmedAt,
                        statusExplanation: statusExplanation,
                      ),
                    ),
                  ),
                  child: ListTile(
                    key: ValueKey(d.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: isPending ? onSurface(context, a55) : null,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitleStr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, isPending ? a40 : a55),
                        ),
                      ),
                    ),
                    trailing: Text(
                      _fmtEur(amountCents),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isPending ? onSurface(context, a55) : null,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPaymentFilterRow(
              context,
              allDocs.length,
              sentCount,
              receivedCount,
            ),
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

/// Width of eight characters in the same style as [KiduCodePill] code text.
double _kiduCodeEightCharWidth(
  TextTheme textTheme, {
  FontWeight fontWeight = FontWeight.w800,
}) {
  final style = textTheme.titleMedium?.copyWith(
    fontWeight: fontWeight,
    letterSpacing: 1.2,
  );
  final tp = TextPainter(
    text: TextSpan(text: 'XXXXXXXX', style: style),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  return tp.width;
}

class KiduCodePill extends StatelessWidget {
  const KiduCodePill({
    super.key,
    required this.code,
    required this.onCopy,
    this.loading = false,
    this.codeFontWeight = FontWeight.w800,
  });

  final String code;
  final VoidCallback onCopy;
  final bool loading;
  final FontWeight codeFontWeight;

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
            child: loading
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: _kiduCodeEightCharWidth(
                        textTheme,
                        fontWeight: codeFontWeight,
                      ),
                      height: 36,
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  )
                : SelectableText(
                    code,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: codeFontWeight,
                      letterSpacing: 1.2,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: () {
                if (loading) return;
                onCopy();
              },
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

  /// Unfocus first (esp. IME) so back-gesture and AppBar back match smoother pops.
  void _popSetupPage([Object? result]) {
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _popSetupPage(result);
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: _popSetupPage),
          title: Text(
            'Koppelen',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: uid == null
              ? KiduCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Niet ingelogd.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: onSurface(context, a68),
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _popSetupPage,
                        child: Text(
                          'Terug',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, a70)),
                        ),
                      ),
                    ],
                  ),
                )
              : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .doc('users/$uid')
                      .snapshots(),
                  builder: (context, snapshot) {
                    final data = snapshot.data?.data();
                    final householdId = (data?['householdId'] as String?)
                        ?.trim();
                    final hasHousehold =
                        householdId != null && householdId.isNotEmpty;

                    if (snapshot.hasError) {
                      return KiduCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Kon status niet laden.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: onSurface(context, a68),
                                    height: 1.35,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: _popSetupPage,
                              child: Text(
                                'Terug',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (!snapshot.hasData) {
                      return KiduCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _popSetupPage,
                              child: Text(
                                'Terug',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return KiduCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Voer een invite-code in om te koppelen aan het household van je co-parent.',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: onSurface(context, a62),
                                  height: 1.35,
                                ),
                          ),
                          const SizedBox(height: 16),
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
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            onPressed: _joinBusy ? null : _joinHousehold,
                            icon: Icon(
                              hasHousehold ? Icons.link : Icons.group_add,
                              size: 18,
                            ),
                            label: Text(
                              _joinBusy
                                  ? 'Bezig...'
                                  : (hasHousehold ? 'Verbinden' : 'Koppelen'),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: _popSetupPage,
                            child: Text(
                              'Terug',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: onSurface(context, a70)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
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
