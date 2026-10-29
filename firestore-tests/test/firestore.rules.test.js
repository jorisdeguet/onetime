const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const firebase = require('firebase/compat/app');
require('firebase/compat/firestore');
const fs = require('fs');
const path = require('path');

const { FieldValue, Timestamp, Blob } = firebase.firestore;

const ALICE = 'alice-uid';
const BOB = 'bob-uid';
const EVE = 'eve-uid';

describe('Firestore security rules', function () {
  this.timeout(20000);
  let testEnv;

  before(async () => {
    const rules = fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
    try {
      testEnv = await initializeTestEnvironment({ projectId: 'onetime-bf68b', firestore: { rules } });
    } catch (err) {
      console.error('\nERROR: Firestore emulator not detected. Run: firebase emulators:exec "npm test"');
      throw err;
    }
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  const db = (uid) => testEnv.authenticatedContext(uid).firestore();

  // Writes test fixtures without going through the rules.
  async function seed(write) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => write(ctx.firestore()));
  }

  function conv(id, peerIds, state = 'ready', extra = {}) {
    return seed((f) => f.doc(`conversations/${id}`).set({ id, peerIds, state, keyDebugInfo: {}, ...extra }));
  }

  function lock(convId, lockerId, createdAt = Timestamp.now()) {
    return seed((f) => f.doc(`conversations/${convId}/locks/conversation_lock`).set({ lockerId, createdAt }));
  }

  function message(bytes = 4) {
    return { ciphertext: Blob.fromUint8Array(new Uint8Array(bytes)), ackSet: ['Tx', 'Rx'], serverTimestamp: FieldValue.serverTimestamp() };
  }

  describe('conversations', () => {
    it('creates a conversation only with yourself in peerIds', async () => {
      await assertSucceeds(db(ALICE).doc('conversations/c1').set({ id: 'c1', peerIds: [ALICE], state: 'joining' }));
      await assertFails(db(EVE).doc('conversations/c2').set({ id: 'c2', peerIds: [ALICE], state: 'joining' }));
    });

    it('does not let outsiders list or read a ready conversation', async () => {
      await conv('c1', [ALICE, BOB]);
      await assertFails(db(EVE).doc('conversations/c1').get());
      await assertFails(db(EVE).collection('conversations').get());
      await assertFails(db(EVE).collection('conversations').where('peerIds', 'array-contains', ALICE).get());
      await assertSucceeds(db(ALICE).collection('conversations').where('peerIds', 'array-contains', ALICE).get());
    });

    it('lets someone with the invitation read and join a joining conversation', async () => {
      await conv('c1', [ALICE], 'joining');
      await assertSucceeds(db(BOB).doc('conversations/c1').get());
      await assertSucceeds(db(BOB).doc('conversations/c1').update({ peerIds: FieldValue.arrayUnion(BOB) }));
    });

    it('reports a missing conversation instead of denying', async () => {
      await assertSucceeds(db(BOB).doc('conversations/nope').get());
    });

    it('refuses joining for someone else, joining a ready conversation, or changing other fields', async () => {
      await conv('c1', [ALICE], 'joining');
      await assertFails(db(EVE).doc('conversations/c1').update({ peerIds: [ALICE, EVE, BOB] }));
      await assertFails(db(EVE).doc('conversations/c1').update({ peerIds: [EVE] }));
      await assertFails(db(EVE).doc('conversations/c1').update({ peerIds: FieldValue.arrayUnion(EVE), state: 'ready' }));
      await conv('c2', [ALICE], 'ready');
      await assertFails(db(EVE).doc('conversations/c2').update({ peerIds: FieldValue.arrayUnion(EVE) }));
    });

    it('lets a member write only their own keyDebugInfo', async () => {
      await conv('c1', [ALICE, BOB]);
      await assertSucceeds(db(ALICE).doc('conversations/c1').update({ [`keyDebugInfo.${ALICE}`]: { startByte: 10, endByte: 100 } }));
      await assertFails(db(ALICE).doc('conversations/c1').update({ [`keyDebugInfo.${BOB}`]: { startByte: 99, endByte: 100 } }));
    });

    it('lets only members delete', async () => {
      await conv('c1', [ALICE, BOB]);
      await assertFails(db(EVE).doc('conversations/c1').delete());
      await assertSucceeds(db(BOB).doc('conversations/c1').delete());
    });
  });

  describe('messages', () => {
    beforeEach(() => conv('c1', [ALICE, BOB]));

    it('hides messages from outsiders', async () => {
      await seed((f) => f.doc('conversations/c1/messages/0-4').set(message()));
      await assertFails(db(EVE).doc('conversations/c1/messages/0-4').get());
      await assertFails(db(EVE).collection('conversations/c1/messages').get());
      await assertSucceeds(db(BOB).collection('conversations/c1/messages').get());
    });

    it('requires holding the send lock', async () => {
      await assertFails(db(ALICE).doc('conversations/c1/messages/0-4').set(message()));
      await lock('c1', BOB);
      await assertFails(db(ALICE).doc('conversations/c1/messages/0-4').set(message()));
      await lock('c1', ALICE);
      await assertSucceeds(db(ALICE).doc('conversations/c1/messages/0-4').set(message()));
    });

    it('refuses an outsider even if they somehow hold the lock', async () => {
      await lock('c1', EVE);
      await assertFails(db(EVE).doc('conversations/c1/messages/0-4').set(message()));
    });

    it('requires the ciphertext length to match the key range in the id', async () => {
      await lock('c1', ALICE);
      await assertFails(db(ALICE).doc('conversations/c1/messages/0-4').set(message(5)));
      await assertFails(db(ALICE).doc('conversations/c1/messages/abc').set(message()));
    });

    it('never accepts a second ciphertext for the same key range', async () => {
      await lock('c1', ALICE);
      await assertSucceeds(db(ALICE).doc('conversations/c1/messages/0-4').set(message()));
      await assertFails(db(ALICE).doc('conversations/c1/messages/0-4').set(message()));
      await assertFails(db(BOB).doc('conversations/c1/messages/0-4').update({ ciphertext: Blob.fromUint8Array(new Uint8Array([1, 2, 3, 4])) }));
    });

    it('lets members add acks and clear the ciphertext, but not remove acks', async () => {
      await seed((f) => f.doc('conversations/c1/messages/0-4').set(message()));
      const ref = db(BOB).doc('conversations/c1/messages/0-4');
      await assertSucceeds(ref.update({ ackSet: ['Tx', 'Rx', 'Ty'] }));
      await assertFails(ref.update({ ackSet: ['Ty'] }));
      await assertSucceeds(ref.update({ ackSet: ['Tx', 'Rx', 'Ty'], ciphertext: '' }));
      await assertFails(db(EVE).doc('conversations/c1/messages/0-4').update({ ackSet: ['Tx', 'Rx', 'Ty', 'Te'] }));
    });
  });

  describe('send lock', () => {
    beforeEach(() => conv('c1', [ALICE, BOB]));
    const lockRef = (uid) => db(uid).doc('conversations/c1/locks/conversation_lock');

    it('lets a member take a free lock with a server timestamp only', async () => {
      await assertFails(lockRef(ALICE).set({ lockerId: ALICE, createdAt: Timestamp.now() }));
      await assertFails(lockRef(ALICE).set({ lockerId: BOB, createdAt: FieldValue.serverTimestamp() }));
      await assertSucceeds(lockRef(ALICE).set({ lockerId: ALICE, createdAt: FieldValue.serverTimestamp() }));
      await assertFails(lockRef(EVE).set({ lockerId: EVE, createdAt: FieldValue.serverTimestamp() }));
    });

    it('refuses stealing a live lock, whatever the client clock says', async () => {
      await lock('c1', BOB);
      await assertFails(lockRef(ALICE).set({ lockerId: ALICE, createdAt: FieldValue.serverTimestamp() }));
      await assertFails(lockRef(ALICE).delete());
      await assertSucceeds(lockRef(BOB).delete());
    });

    it('allows taking over a lock older than 5 minutes', async () => {
      await lock('c1', BOB, Timestamp.fromMillis(Date.now() - 6 * 60 * 1000));
      await assertSucceeds(lockRef(ALICE).set({ lockerId: ALICE, createdAt: FieldValue.serverTimestamp() }));
    });
  });

  describe('key exchange sessions', () => {
    const session = () => ({
      id: 'k1', sourceId: ALICE, participants: [ALICE, BOB], status: 'inProgress',
      segmentsByPeer: { [ALICE]: [0, 1], [BOB]: [] }, totalSegments: 2, startIndex: 0, endIndex: 2,
    });
    const seedSession = () => seed((f) => f.doc('kex/k1').set(session()));

    it('creates a session only as its source and participant', async () => {
      await assertSucceeds(db(ALICE).doc('kex/k1').set(session()));
      await assertFails(db(EVE).doc('kex/k2').set(session()));
      await assertFails(db(EVE).doc('kex/k3').set({ ...session(), sourceId: EVE }));
    });

    it('hides sessions from outsiders', async () => {
      await seedSession();
      await assertFails(db(EVE).doc('kex/k1').get());
      await assertFails(db(EVE).doc('kex/k1').delete());
      await assertSucceeds(db(BOB).collection('kex').where('participants', 'array-contains', BOB).get());
    });

    it('lets a reader record only their own scans', async () => {
      await seedSession();
      await assertSucceeds(db(BOB).doc('kex/k1').update({ segmentsByPeer: { [ALICE]: [0, 1], [BOB]: [0] }, updatedAt: FieldValue.serverTimestamp() }));
      await assertFails(db(BOB).doc('kex/k1').update({ segmentsByPeer: { [ALICE]: [0], [BOB]: [0] } }));
    });

    it('lets only the source change status or segment count', async () => {
      await seedSession();
      await assertFails(db(BOB).doc('kex/k1').update({ status: 'completed' }));
      await assertFails(db(BOB).doc('kex/k1').update({ totalSegments: 1 }));
      await assertSucceeds(db(ALICE).doc('kex/k1').update({ status: 'completed', totalSegments: 1 }));
      await assertFails(db(ALICE).doc('kex/k1').update({ sourceId: BOB }));
    });
  });
});
