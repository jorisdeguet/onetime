# OneTime security review (2026-11-11)

Scope: Firestore rules, key generation, storage and use, message format, key
exchange (QR and Bluetooth). Threat model: the **server is the adversary**
(Google, the Firebase project owner, or anyone with its admin credentials).
That is the only reason to use a one-time pad instead of a normal messenger,
so every finding is judged against it.

## Findings, most severe first

### 1. HIGH: the pad is backed up to Google Drive and iCloud (fixed)

*Fixed: `allowBackup="false"` and `dataExtractionRules` excluding cloud backup and device transfer on Android, verified with `bmgr backupnow` ("Backup is not allowed"). On iOS the `conversations` folder is marked `isExcludedFromBackup` through the `onetime/storage` channel (not yet run on an iPhone). The folder also holds decrypted messages, which were exposed the same way.*

`LocalStorageService` stores `key.bin` under `getApplicationDocumentsDirectory()`.
- **Android:** the manifest sets neither `allowBackup` nor `dataExtractionRules`, so Auto Backup is on by default. It copies that folder to the user's Google Drive and also to a new phone during device transfer.
- **iOS:** the Documents folder is in iCloud backups.

Google then holds both the pad (backup) and the ciphertexts (Firestore). This voids the scheme without any cryptanalysis.

Fix:
- **Android:** set `android:allowBackup="false"` and add `dataExtractionRules` that exclude everything, including device transfer.
- **iOS:** store keys under Library/Application Support with `NSURLIsExcludedFromBackupKey`.

### 2. HIGH: messages have no integrity or authentication (fixed)

*Fixed: each message now uses 32 more pad bytes as a one-time Poly1305 key; the 16-byte tag over the ciphertext is checked before decrypting, and a rejected message consumes no key bytes. The Firestore rule now requires `ciphertext.size() == range - 16`.*

`CryptoService` XORs the protobuf with the pad and nothing else. A one-time pad is perfectly *malleable*: flipping ciphertext bit *i* flips plaintext bit *i*. Whoever can write Firestore outside the rules (the server) can do the following.
- **Change the sender.** `senderId` is only inside the encrypted protobuf at a predictable offset, and peer ids are public (`peerIds`). XORing `old_id ⊕ new_id` there makes a message appear to come from another member.
- **Rewrite guessable content** ("oui" ↔ "non", amounts, times) and timestamps.
- **Forge a message at a range far ahead.** The receiver decrypts garbage and then deletes all pad bytes before that range. This burns the key.
- **Drop or reorder messages** without either side noticing.

Fix: a Wegman–Carter one-time MAC (see Literature). It is information-theoretically secure, so it keeps the pad's guarantee, and it costs about 32 pad bytes per message.

### 3. MEDIUM: any member (or the server) can burn the whole pad

- `_syncWithFirestoreKeyState` advances the local key to the **maximum** `keyDebugInfo.startByte` of all members.
- The rules let each member write their own `keyDebugInfo` freely.

So one member, or the server, writing `startByte = 10^9` makes every other phone discard its entire key. The same update rule also lets any member:
- rewrite `peerIds` (remove the others, add someone);
- change `state` and `totalKeyBytes`.

Fix:
- Never move the counter forward from unauthenticated server data. With finding 7's per-sender ranges, nothing needs syncing.
- Restrict `peerIds` changes to the joining flow.

### 4. MEDIUM: conversation ids are guessable, so a stranger can join

- The invitation QR contains only the conversation id, `conv_<ms>_<creatorUid>`.
- While `state == 'joining'`, any signed-in user can add themselves (`isJoining`). Sign-in is anonymous, so that means anyone.
- An attacker who knows the creator's uid can try the ids around the current time.

An intruder never gets key bytes, because those are physical-only. But they become a key-exchange participant:
- the source keeps only segments acknowledged by *all* participants, so the exchange stalls (denial of service);
- they can also take the send lock and delete messages.

Fix: a random 128-bit id or join token (Firestore `doc().id` is about 120 bits). Also show the joined members' pseudonyms before "Valider".

### 5. MEDIUM (claim): the pad comes from a CSPRNG, not true randomness

`KeyService._generateRandomBytes` uses `Random.secure()`, which reads the OS CSPRNG. The pad therefore has at most the entropy of the generator's seed, a few hundred bits. Its security is the CSPRNG's (computational, comparable to ChaCha20), not Shannon's.

This is very safe in practice, but "information-theoretically secure" is not strictly true. If the app makes that claim, either qualify it or improve it:
- XOR in independent physical entropy (camera sensor noise, microphone) through a randomness extractor. Toeplitz hashing is cheap and proven.
- Better: have **both** phones contribute and XOR their contributions. The pad is then random as long as *either* phone's generator is sound. This needs the reader to send its part, e.g. over Bluetooth (encrypted by the invite) or via the reader's screen.

### 6. LOW: no key confirmation after an exchange

The fountain packets carry no checksum. They rely on QR Reed–Solomon, and in Bluetooth mode on GCM. A misdecoded segment would leave the two pads silently different, and every later message would come out as garbage. The MAC from finding 2 detects this on the first message.

An explicit check at the end of the exchange is cleaner: a Wegman–Carter tag over the whole pad, computed with the first 32 bytes, which are then discarded. Do not use a plain hash: it leaks information about the pad.

### 7. LOW: a stolen lock can expose a two-time pad to the server

The send lock expires after 5 minutes and is never renewed. A slow upload (a large photo on a bad connection) can lose the lock. The other member then sends at the same `nextAvailableByte`.
- The rules reject the first sender's write, so the stored messages stay correct.
- But the rejected payload has still reached Google's servers. The server has now seen two ciphertexts under the same pad bytes, and P1 ⊕ P2 is recoverable.

Fix: give each member a fixed, separate part of the pad. With two members, one sends from the start and the other from the end, meeting in the middle. With N members, use N slices. Key reuse then becomes impossible by construction, and the lock and the keyDebugInfo sync (finding 3) can be removed. This is how operational one-time pad systems have always worked (one pad per direction).

### 8. LOW: used pad bytes survive on flash

`truncateKeyPrefix` writes a new file and deletes the old one. Flash wear-levelling keeps the old blocks, which can be recovered with forensic access to a seized phone.

The one-time pad's "forward secrecy by deletion" is only as good as deletion. Reardon et al., *SoK: Secure Data Deletion* (IEEE S&P 2013), conclude that only cryptographic erasure is reliable:
- encrypt each pad chunk at rest with a key held in the Android Keystore or iOS Secure Enclave;
- destroy that key once the chunk is used.

This makes the stored pad only computationally protected at rest, against an attacker who seizes the phone. It is a real tradeoff to decide on purpose.

### 9. LOW: metadata visible to the server

- The message id `<start>-<end>` reveals each message's exact length. Compression makes the length depend on content.
- The lock document reveals **who** sends each message, and when.
- `ackSet` reveals who read what, and when.

Fix:
- Pad payloads to size buckets, as in Padmé (Nikitin et al., PETS 2019). This costs pad bytes, so make it optional, e.g. for text only.
- Per-sender ranges (finding 7) also remove the lock.

### 10. LOW: members can make others lose messages

Any peer can add every id to `ackSet` and clear `ciphertext` before the others have read it. Any peer can also delete messages. A malicious member is outside the main threat model, but the rule could require `uid()` to be the only id it adds to `ackSet`.

## What is sound

- The pad bytes never touch the network in QR mode. The Firestore `kex` documents hold only acknowledgements, and the rules confine readers to their own entries.
- Message creation requires the lock, a ciphertext length equal to the range, and no overwrite. A ciphertext can only be cleared, never replaced, through the rules.
- Bluetooth mode:
  - Forged or replayed packets fail AES-GCM.
  - The nonce counter is used by the source only.
  - Unauthenticated control messages can only slow the exchange.
  - The security level, AES-256, is stated in the UI.
- Test-only logs (`TestEvents`, key fingerprints) are disabled in release builds.
- A one-time pad is post-quantum by nature. AES-256 in Bluetooth mode keeps about 128 bits against Grover's algorithm, which is fine.

## Literature

**Is there any doubt on the Vernam cipher?** None on the theory.
- Shannon (1949) proved perfect secrecy under four conditions:
  - the key is truly uniform;
  - it is at least as long as the message;
  - it is used once;
  - it is kept secret.
- The result is also *composable*: it stays secure inside larger protocols, which is why QKD uses it (Portmann & Renner 2014).
- Every historical break was a violation of a condition, never of the theorem:
  - **VENONA:** Soviet pads were reused, and about 3,000 messages were decrypted.
  - **Weak generation:** some machine-generated "random" pads were not random enough.
  - **Captured or copied pads.**
- The same three weak points appear in this app as findings 5, 7 and 1/8.

**The well-known gaps** are not about secrecy:
1. **Malleability and no authentication.** A one-time pad gives secrecy only. Wegman & Carter (1981) give the matching unconditional MAC:
   - take a polynomial hash of the message, over GF(2¹²⁸) or a prime field, keyed by fresh pad bytes;
   - encrypt the tag with more pad bytes.
   - A forgery succeeds with probability at most ℓ/2¹²⁸ for an ℓ-block message, whatever the attacker's computing power.
   - Poly1305 is this construction with a computational key.
   - Portmann (2014, *Key recycling in authentication*) shows most of the MAC key can even be reused safely when verification succeeds, which cuts the cost to about 16 bytes per message.
2. **Key distribution.** This is exactly what the QR exchange solves, by assuming the visual channel is private. That assumption has limits:
   - screens and QR codes can be read from reflections (Backes et al., *Compromising Reflections*, IEEE S&P 2008), cameras or CCTV;
   - the app should advise exchanging in private, with low brightness.
3. **Group authentication.** With one shared pad, any member can impersonate any other. A MAC proves "a member wrote this", not *which* member. Per-member pad slices (finding 7) plus per-sender MAC keys fix this within the group.

**Recommended changes, in order:**
1. Disable backups (finding 1).
2. Add a Wegman–Carter MAC, with the key range and sender id in the authenticated data (findings 2, 6).
3. Give each sender its own part of the pad and drop the lock and keyDebugInfo sync (findings 3, 7).
4. Random conversation ids (finding 4).
5. Mix entropy from both phones (finding 5).
6. Decide on crypto-erasure at rest (finding 8).
