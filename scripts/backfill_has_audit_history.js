#!/usr/bin/env node
/**
 * Backfill `hasAuditHistory: true` on expense documents that already have
 * audit subcollection docs.
 *
 * Usage:
 *   # Dry-run (default — no writes):
 *   node scripts/backfill_has_audit_history.js
 *
 *   # Apply writes:
 *   node scripts/backfill_has_audit_history.js --apply
 *
 * Prerequisites:
 *   - npm install in scripts/ (firebase-admin)
 *   - GOOGLE_APPLICATION_CREDENTIALS pointing to a service account JSON
 *   - GCLOUD_PROJECT or FIREBASE_PROJECT_ID (defaults to kidu-dev-d69fb)
 */

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'kidu-dev-d69fb';
const BATCH_SIZE = 500;

const apply = process.argv.includes('--apply');
const dryRun = !apply;

function readStringList(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((v) => typeof v === 'string');
}

function childIdsEqual(a, b) {
  if (a.length !== b.length) return false;
  const setA = new Set(a);
  for (const id of b) {
    if (!setA.has(id)) return false;
  }
  return true;
}

function childIdsChanged(data) {
  const prior = readStringList(data.priorChildIds);
  const next = readStringList(data.childIds);
  return !childIdsEqual(prior, next);
}

function splitChanged(data) {
  if (!Object.prototype.hasOwnProperty.call(data, 'priorSplitParticipantUids')) {
    return false;
  }
  const priorUids = readStringList(data.priorSplitParticipantUids);
  const nextUids = readStringList(data.splitParticipantUids);
  const priorBps = data.priorSplit0ShareBps;
  const nextBps = data.split0ShareBps;
  if (priorUids.length !== nextUids.length) return true;
  for (let i = 0; i < priorUids.length; i += 1) {
    if (priorUids[i] !== nextUids[i]) return true;
  }
  return priorBps !== nextBps;
}

function expenseChangeHasValidAudit(data) {
  return childIdsChanged(data) || splitChanged(data);
}

async function expenseHasAuditHistory(db, expenseRef) {
  const amountSnap = await expenseRef.collection('amountEdits').limit(1).get();
  if (!amountSnap.empty) {
    return { hasAudit: true, viaAmountEdits: true, viaExpenseChanges: false };
  }

  const changeSnap = await expenseRef.collection('expenseChanges').get();
  for (const doc of changeSnap.docs) {
    if (expenseChangeHasValidAudit(doc.data())) {
      return { hasAudit: true, viaAmountEdits: false, viaExpenseChanges: true };
    }
  }

  return { hasAudit: false, viaAmountEdits: false, viaExpenseChanges: false };
}

async function main() {
  const projectId =
    process.env.GCLOUD_PROJECT ||
    process.env.FIREBASE_PROJECT_ID ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    DEFAULT_PROJECT_ID;

  if (!admin.apps.length) {
    admin.initializeApp({ projectId });
  }
  const db = admin.firestore();

  const stats = {
    projectId,
    mode: dryRun ? 'dry-run' : 'apply',
    householdsScanned: 0,
    expensesScanned: 0,
    withAmountEdits: 0,
    withValidExpenseChanges: 0,
    needsUpdate: 0,
    writesExecuted: 0,
    skippedAlreadyTrue: 0,
    errors: 0,
  };

  console.log(`Project: ${projectId}`);
  console.log(`Mode: ${stats.mode}`);
  console.log('---');

  let batch = db.batch();
  let batchCount = 0;

  async function commitBatch() {
    if (batchCount === 0) return;
    if (!dryRun) {
      await batch.commit();
      stats.writesExecuted += batchCount;
    }
    batch = db.batch();
    batchCount = 0;
  }

  try {
    const householdsSnap = await db.collection('households').get();
    stats.householdsScanned = householdsSnap.size;

    for (const householdDoc of householdsSnap.docs) {
      const expensesSnap = await householdDoc.ref.collection('expenses').get();

      for (const expenseDoc of expensesSnap.docs) {
        stats.expensesScanned += 1;

        const expenseData = expenseDoc.data();
        if (expenseData.hasAuditHistory === true) {
          stats.skippedAlreadyTrue += 1;
          continue;
        }

        let auditResult;
        try {
          auditResult = await expenseHasAuditHistory(db, expenseDoc.ref);
        } catch (err) {
          stats.errors += 1;
          console.error(
            `Error scanning ${expenseDoc.ref.path}: ${err.message || err}`,
          );
          continue;
        }

        if (auditResult.viaAmountEdits) {
          stats.withAmountEdits += 1;
        }
        if (auditResult.viaExpenseChanges) {
          stats.withValidExpenseChanges += 1;
        }

        if (!auditResult.hasAudit) {
          continue;
        }

        stats.needsUpdate += 1;
        console.log(
          `${dryRun ? '[dry-run] would update' : 'updating'} ${expenseDoc.ref.path}`,
        );

        if (!dryRun) {
          batch.update(expenseDoc.ref, { hasAuditHistory: true });
          batchCount += 1;
          if (batchCount >= BATCH_SIZE) {
            await commitBatch();
          }
        }
      }
    }

    await commitBatch();
  } catch (err) {
    console.error(`Fatal error: ${err.message || err}`);
    process.exit(1);
  }

  console.log('---');
  console.log('Summary:');
  console.log(`  households scanned:        ${stats.householdsScanned}`);
  console.log(`  expenses scanned:          ${stats.expensesScanned}`);
  console.log(`  with amountEdits:          ${stats.withAmountEdits}`);
  console.log(`  with valid expenseChanges: ${stats.withValidExpenseChanges}`);
  console.log(`  already hasAuditHistory:   ${stats.skippedAlreadyTrue}`);
  console.log(`  needs update:              ${stats.needsUpdate}`);
  console.log(
    `  writes executed:             ${dryRun ? 0 : stats.writesExecuted}`,
  );
  console.log(`  errors:                    ${stats.errors}`);

  if (dryRun && stats.needsUpdate > 0) {
    console.log('');
    console.log('Re-run with --apply to write changes.');
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
