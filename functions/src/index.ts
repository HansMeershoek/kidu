/**
 * KiDu — Fase 4 / 4b: server-side cleanup rond household-lifecycle.
 *
 * Firestore verwijdert subcollecties niet automatisch wanneer een parent
 * document wordt verwijderd. Deze Cloud Functions zijn de enige plek die
 * household-trees server-side opruimen:
 * - `deleteReadOnlyHouseholdAndAccount` (Fase 4): definitieve cleanup voor
 *   de laatste overblijvende ouder in een read-only huishouden.
 * - `deleteEmptySoloHousehold` (Fase 4b): opruimen van een leeg orphan
 *   solo-household nadat een ouder via een invitecode is gekoppeld.
 * Alle validatie gebeurt hier, nooit op basis van ongecontroleerde
 * client-input.
 */

import { setGlobalOptions } from "firebase-functions/v2";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";

admin.initializeApp();

// Geen bestaande Functions-regio gevonden in dit project (nieuwe functions/
// map) — europe-west1 gekozen omdat KiDu Nederlandstalig is en dit
// waarschijnlijk dichter bij de gebruikers zit. Consequent gebruikt in
// zowel deze functie als de Flutter-callable (zie account_delete_controller.dart).
const REGION = "europe-west1";
setGlobalOptions({ region: REGION });

/** Marker gezet vóór destructieve writes, zodat een mislukte poging veilig
 * opnieuw kan worden geprobeerd (zie idempotentie-sectie in de opdracht). */
const CLEANUP_MARKER_STATE = "readOnlyFinalCleanupStarted";

/** Hoe oud `auth_time` (in seconden sinds epoch) maximaal mag zijn. */
const RECENT_LOGIN_MAX_AGE_SECONDS = 5 * 60;

const db = admin.firestore();

/**
 * Verwijdert de Firebase Auth user via de Admin SDK. Idempotent: als de
 * user al niet meer bestaat (eerdere poging is al gelukt), wordt dat als
 * succes behandeld in plaats van als fout.
 */
async function deleteAuthUserIdempotently(uid: string): Promise<void> {
  try {
    await admin.auth().deleteUser(uid);
  } catch (error) {
    if ((error as { code?: string } | undefined)?.code === "auth/user-not-found") {
      return;
    }
    logger.error(
      `deleteReadOnlyHouseholdAndAccount: Auth delete failed for uid=${uid}`,
      error,
    );
    throw new HttpsError(
      "internal",
      "Account verwijderen is niet gelukt. Probeer het opnieuw.",
    );
  }
}

/**
 * Best-effort opruimen van de eerder geminimaliseerde user-doc van de
 * eerste verwijderde ouder (`households/{id}.readOnlyBy`). Faalt nooit
 * naar de caller: bij twijfel of fout wordt alleen gelogd.
 */
async function deleteMinimizedUserDocIfSafe(
  uid: unknown,
  currentUid: string,
): Promise<void> {
  if (typeof uid !== "string") {
    logger.info("deleteMinimizedUserDocIfSafe: skipped, no uid");
    return;
  }
  const trimmedUid = uid.trim();
  if (trimmedUid.length === 0) {
    logger.info("deleteMinimizedUserDocIfSafe: skipped, no uid");
    return;
  }
  if (trimmedUid === currentUid) {
    logger.info("deleteMinimizedUserDocIfSafe: skipped, same uid");
    return;
  }

  try {
    const previousUserRef = db.doc(`users/${trimmedUid}`);
    const previousUserSnap = await previousUserRef.get();
    if (!previousUserSnap.exists) {
      return;
    }

    const data = previousUserSnap.data() ?? {};
    const isMinimized =
      (data.email === null || data.email === undefined) &&
      (data.displayName === null || data.displayName === undefined) &&
      (data.photoUrl === null || data.photoUrl === undefined) &&
      (data.profileName === null || data.profileName === undefined) &&
      (data.householdId === null || data.householdId === undefined);

    if (!isMinimized) {
      logger.warn(
        `deleteMinimizedUserDocIfSafe: skipped, doc not minimized uid=${trimmedUid}`,
      );
      return;
    }

    try {
      await admin.auth().getUser(trimmedUid);
      logger.warn(
        `deleteMinimizedUserDocIfSafe: skipped, auth user still exists uid=${trimmedUid}`,
      );
      return;
    } catch (authError) {
      if (
        (authError as { code?: string } | undefined)?.code !==
        "auth/user-not-found"
      ) {
        logger.error(
          `deleteMinimizedUserDocIfSafe: auth lookup failed uid=${trimmedUid}`,
          authError,
        );
        return;
      }
    }

    await previousUserRef.delete();
    logger.info(
      `deleteMinimizedUserDocIfSafe: deleted previous minimized user doc uid=${trimmedUid}`,
    );
  } catch (error) {
    logger.error(
      `deleteMinimizedUserDocIfSafe: delete failed uid=${trimmedUid}`,
      error,
    );
  }
}

/**
 * Verwijdert alle invite-docs die naar `householdId` verwijzen, in veilige
 * chunks via een BulkWriter. Neemt niet aan dat er maar één invite is.
 */
async function deleteInvitesForHousehold(householdId: string): Promise<void> {
  const bulkWriter = db.bulkWriter();
  const pageSize = 300;
  let lastDoc: admin.firestore.QueryDocumentSnapshot | undefined;

  try {
    for (;;) {
      let query = db
        .collection("invites")
        .where("householdId", "==", householdId)
        .limit(pageSize);
      if (lastDoc) {
        query = query.startAfter(lastDoc);
      }

      const snap = await query.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        bulkWriter.delete(doc.ref);
      }

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < pageSize) break;
    }
  } finally {
    await bulkWriter.close();
  }
}

export const deleteReadOnlyHouseholdAndAccount = onCall(
  { region: REGION },
  async (request) => {
    const auth = request.auth;
    if (!auth) {
      throw new HttpsError("unauthenticated", "Je bent niet (meer) ingelogd.");
    }
    const uid = auth.uid;

    const rawHouseholdId = request.data?.householdId;
    if (typeof rawHouseholdId !== "string" || rawHouseholdId.trim().length === 0) {
      throw new HttpsError("invalid-argument", "householdId is verplicht.");
    }
    const householdId = rawHouseholdId.trim();

    // Recente login: de Flutter-flow doet Google re-auth vlak voor deze
    // call en forceert daarna een verse ID-token via getIdToken(true).
    // auth_time (seconden sinds epoch) moet daardoor vers zijn.
    const authTime = auth.token.auth_time;
    if (typeof authTime !== "number") {
      throw new HttpsError(
        "failed-precondition",
        "recent-login-required: kan recente aanmelding niet verifiëren.",
      );
    }
    const authAgeSeconds = Date.now() / 1000 - authTime;
    if (authAgeSeconds > RECENT_LOGIN_MAX_AGE_SECONDS) {
      throw new HttpsError(
        "failed-precondition",
        "recent-login-required: aanmelding is te oud, log opnieuw in.",
      );
    }

    const userRef = db.doc(`users/${uid}`);
    const userSnap = await userRef.get();

    if (!userSnap.exists) {
      // Alles Firestore-side is al opgeruimd door een eerdere poging; het
      // enige dat nog kan resteren is de Auth-delete zelf.
      await deleteAuthUserIdempotently(uid);
      return { ok: true };
    }

    const userData = userSnap.data() ?? {};
    const isRetry =
      userData.accountDeletionState === CLEANUP_MARKER_STATE &&
      userData.accountDeletionHouseholdId === householdId;

    if (!isRetry) {
      const userHouseholdId =
        typeof userData.householdId === "string" ? userData.householdId.trim() : null;
      if (userHouseholdId !== householdId) {
        throw new HttpsError(
          "failed-precondition",
          "Dit account is niet gekoppeld aan dit huishouden.",
        );
      }
    }

    const householdRef = db.doc(`households/${householdId}`);
    const householdSnap = await householdRef.get();

    // Bewaar vóór recursiveDelete: wijst naar de ouder die als eerste via
    // activeWithCoParent vertrok. Alleen op de happy path beschikbaar.
    let firstDeletedUid: unknown;

    if (!householdSnap.exists) {
      if (!isRetry) {
        throw new HttpsError(
          "failed-precondition",
          "Huishouden bestaat niet (meer).",
        );
      }
      // Retry: een eerdere poging heeft de household-tree al verwijderd.
    } else {
      const householdData = householdSnap.data() ?? {};
      if (householdData.isReadOnly !== true) {
        throw new HttpsError("failed-precondition", "Huishouden is niet read-only.");
      }

      firstDeletedUid = householdData.readOnlyBy;

      const membersSnap = await householdRef.collection("members").get();
      const memberIds = membersSnap.docs.map((doc) => doc.id);

      if (memberIds.length === 0) {
        if (!isRetry) {
          throw new HttpsError(
            "permission-denied",
            "Je bent geen lid (meer) van dit huishouden.",
          );
        }
        // Retry: het eigen member-doc is al verwijderd in een eerdere poging.
      } else if (memberIds.length > 1 || memberIds[0] !== uid) {
        throw new HttpsError(
          "failed-precondition",
          "Er zijn nog meerdere leden in dit huishouden.",
        );
      }
    }

    // 1. Markeer cleanup als gestart en minimaliseer users/{uid} vóórdat
    //    er iets destructiefs gebeurt, zodat een mislukte retry dit kan
    //    herkennen.
    await userRef.set(
      {
        email: null,
        photoUrl: null,
        displayName: null,
        profileName: null,
        householdId: null,
        accountDeletionState: CLEANUP_MARKER_STATE,
        accountDeletionHouseholdId: householdId,
        accountDeletionStartedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    // 2. Verwijder invite-docs die naar dit huishouden verwijzen.
    await deleteInvitesForHousehold(householdId);

    // 3. Verwijder de volledige household-tree (root-doc + alle
    //    subcollecties), server-side via de Admin SDK.
    if (householdSnap.exists) {
      await db.recursiveDelete(householdRef);
    }

    // 4. Verwijder de Firebase Auth user.
    await deleteAuthUserIdempotently(uid);

    // 5. Best-effort: verwijder het al geminimaliseerde user-doc. Faalt dit
    //    alsnog, dan gooien we geen fout naar de client — de Auth-user is
    //    dan al weg en het doc bevat geen PII meer. Alleen server-side loggen.
    try {
      await userRef.delete();
    } catch (error) {
      logger.error(
        `deleteReadOnlyHouseholdAndAccount: failed to delete users/${uid} after auth delete`,
        error,
      );
    }

    // 6. Best-effort: ruim de eerder geminimaliseerde user-doc van de
    //    eerste verwijderde ouder op (readOnlyBy). Faalt dit, dan blijft
    //    de hoofdcleanup succesvol.
    await deleteMinimizedUserDocIfSafe(firstDeletedUid, uid);

    return { ok: true };
  },
);

/**
 * KiDu — Fase 4b: opruimen van een leeg orphan solo-household nadat een
 * ouder via een invitecode is gekoppeld aan een ander (gedeeld) household.
 *
 * Wanneer ouder B een account aanmaakt krijgt die eerst een eigen
 * solo-household. Voert B daarna de invitecode van ouder A in, dan wordt
 * B's `users/{uid}.householdId` gewijzigd naar A's household en wordt B's
 * member-doc onder het oude solo-household verwijderd — maar het lege
 * root-document van dat oude solo-household blijft achter. Deze callable
 * ruimt dat root-document op, maar alléén als server-side is vastgesteld
 * dat het echt leeg is en bij de aanroeper hoort. Faalt deze check, dan
 * wordt niets verwijderd; de koppeling zelf hangt hier nooit van af.
 */
export const deleteEmptySoloHousehold = onCall(
  { region: REGION },
  async (request) => {
    const auth = request.auth;
    if (!auth) {
      throw new HttpsError("unauthenticated", "Je bent niet (meer) ingelogd.");
    }
    const uid = auth.uid;

    const rawHouseholdId = request.data?.householdId;
    if (typeof rawHouseholdId !== "string" || rawHouseholdId.trim().length === 0) {
      throw new HttpsError("invalid-argument", "householdId is verplicht.");
    }
    const householdId = rawHouseholdId.trim();

    const householdRef = db.doc(`households/${householdId}`);
    const householdSnap = await householdRef.get();

    if (!householdSnap.exists) {
      // Idempotent: een eerdere (of gelijktijdige) cleanup-poging heeft dit
      // household al verwijderd. Geen fout, niets te doen.
      return { ok: true, deleted: false };
    }

    const householdData = householdSnap.data() ?? {};
    if (householdData.createdBy !== uid) {
      // Nooit een household van iemand anders opruimen, ook niet als het
      // toevallig leeg is.
      throw new HttpsError(
        "permission-denied",
        "Je bent niet de eigenaar van dit huishouden.",
      );
    }

    if (householdData.isConnected === true) {
      // isConnected true betekent dat dit géén los solo-orphan (meer) is;
      // dit hoort dan niet stilletjes opgeruimd te worden.
      return { ok: true, deleted: false, reason: "not-solo" };
    }

    // listCollections() ontdekt élke subcollectie op dit document, niet
    // alleen de bekende namen (members, children, expenses, payments,
    // changes, privateNotes, monthlyExpenses, ...) — zo blijft de check
    // ook kloppen als er later nieuwe subcollecties bijkomen.
    const subcollections = await householdRef.listCollections();
    for (const subcollection of subcollections) {
      const anyDocSnap = await subcollection.limit(1).get();
      if (!anyDocSnap.empty) {
        // Er staat nog data onder dit household — dit is dan geen lege
        // orphan (meer) en wordt niet verwijderd.
        return { ok: true, deleted: false, reason: "not-empty" };
      }
    }

    // Alle checks geslaagd: bewezen leeg solo-household van de aanroeper
    // zelf. Geen recursiveDelete nodig, want er zijn geen subcollectie-
    // documenten gevonden — een simpele delete van het root-doc is genoeg.
    await householdRef.delete();

    return { ok: true, deleted: true };
  },
);
