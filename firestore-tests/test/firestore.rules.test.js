const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const fs = require('fs');
const path = require('path');
const { expect } = require('chai');

describe('Firestore security rules', function() {
  this.timeout(20000);
  let testEnv;
  const rulesPath = path.join(__dirname, '..', '..', 'firestore.rules');
  let rules;

  before(async () => {
    rules = fs.readFileSync(rulesPath, 'utf8');
    try {
      testEnv = await initializeTestEnvironment({
        projectId: 'onetime-bf68b',
        firestore: { rules },
      });
    } catch (err) {
      console.error('\nERROR: Firestore emulator not detected.\nPlease run the tests with the emulator:');
      console.error('  firebase emulators:exec "npm test"');
      throw err;
    }
  });

  after(async () => {
    if (testEnv) {
      await testEnv.clearFirestore();
      await testEnv.cleanup();
    }
  });

  it('allows creating key_exchange_session when authenticated and participant', async () => {
    const alice = testEnv.authenticatedContext('alice-uid');
    const db = alice.firestore();

    const sessionRef = db.collection('key_exchange_sessions').doc('sess1');
    await assertSucceeds(sessionRef.set({ participants: ['alice-uid', 'bob-uid'] }));
  });

  it('prevents creating key_exchange_session when not a participant', async () => {
    const charlie = testEnv.authenticatedContext('charlie-uid');
    const db = charlie.firestore();

    const sessionRef = db.collection('key_exchange_sessions').doc('sess2');
    await assertFails(sessionRef.set({ participants: ['alice-uid', 'bob-uid'] }));
  });

  it('allows read/write for participant on key_exchange_session', async () => {
    const alice = testEnv.authenticatedContext('alice-uid');
    const db = alice.firestore();
    const sessionRef = db.collection('key_exchange_sessions').doc('sess3');
    await sessionRef.set({ participants: ['alice-uid', 'bob-uid'] });

    await assertSucceeds(sessionRef.get());
    await assertSucceeds(sessionRef.update({ status: 'updated' }));
  });

  it('conversation create only if authenticated and in peerIds', async () => {
    const alice = testEnv.authenticatedContext('alice-uid');
    const db = alice.firestore();
    const convRef = db.collection('conversations').doc('conv1');
    await assertSucceeds(convRef.set({ peerIds: ['alice-uid', 'bob-uid'], state: 'joining' }));

    const charlie = testEnv.authenticatedContext('charlie-uid');
    const db2 = charlie.firestore();
    const convRef2 = db2.collection('conversations').doc('conv2');
    await assertFails(convRef2.set({ peerIds: ['alice-uid', 'bob-uid'], state: 'joining' }));
  });

  it('allows read when user is a peer or conversation is joining', async () => {
    const alice = testEnv.authenticatedContext('alice-uid');
    const db = alice.firestore();
    const convRef = db.collection('conversations').doc('conv3');
    await convRef.set({ peerIds: ['alice-uid', 'bob-uid'], state: 'active' });
    await assertSucceeds(convRef.get());

    // Create conv4 with alice as creator (alice is part of peerIds), state = 'joining'
    const convRef4 = db.collection('conversations').doc('conv4');
    await convRef4.set({ peerIds: ['alice-uid', 'someone-else'], state: 'joining' });

    const david = testEnv.authenticatedContext('david-uid');
    const db4 = david.firestore();
    await assertSucceeds(db4.collection('conversations').doc('conv4').get());
  });

  it('messages subcollection accessible only to peerIds', async () => {
    const alice = testEnv.authenticatedContext('alice-uid');
    const db = alice.firestore();
    const convRef = db.collection('conversations').doc('conv5');
    await convRef.set({ peerIds: ['alice-uid', 'bob-uid'], state: 'active' });

    const msgRef = convRef.collection('messages').doc('m1');
    await assertSucceeds(msgRef.set({ sender: 'alice-uid', text: 'hello' }));

    const charlie = testEnv.authenticatedContext('charlie-uid');
    const db2 = charlie.firestore();
    const msgRef2 = db2.collection('conversations').doc('conv5').collection('messages').doc('m2');
    await assertFails(msgRef2.set({ sender: 'charlie-uid', text: 'hey' }));
  });

});
