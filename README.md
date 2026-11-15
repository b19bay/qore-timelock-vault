# PQ Timelock Vault — QoreChain "Build Before Q-Day" (Post-Quantum dApp)

A vault on QoreChain's EVM with four controls in one contract:

1. **Timelock** — a queued withdrawal can only execute after `queuedAt +
   timelockSeconds`. There is no owner shortcut.
2. **Guardian** — a guardian (or the owner) can cancel a queued withdrawal.
   The guardian can never move funds, change the owner, or change the
   guardian.
3. **Daily limit** — executions in any rolling 24h window may not exceed
   `dailyLimit`.
4. **Post-quantum threshold** — withdrawals above `pqThreshold` require a
   valid **ML-DSA-87** signature by the owner, verified **on-chain** through
   QoreChain's PQC precompiles (`0x0A01` `pqcVerify`, `0x0A02`
   `pqcKeyStatus`).

Testnet / devnet only. Never mainnet. No real funds.

## Deployed

| Network | Vault |
|---|---|
| Local devnet `qorechain-devnet` (EVM 9800) | `0xb6c45e628188DD084879Bc0eEC2813d6c8Fd755D` (v2, current source; owner `0x1A79C62CB23E6813EF82929E25814822A8216776`, guardian `0xd40Ca79AB4f3c02DAe2f64C97e1C5E48dD09aCD5`, timelock 60s, threshold 1 QOR, daily limit 5 QOR) |
| Testnet `qorechain-diana` (EVM 9800) | **`0x2dd1d8b68da66948dd34f0efaab1edc87440e533`** (deployed 16 Nov 2026; owner `0x4ebF42bc963A290EC0c50549ddE011D479723F6b`, guardian `0x428be6e8bb0a96cb3bf2b6bdf5b3176568526a34`, timelock 86400s = 24h, threshold 1 QOR, daily limit 5 QOR; deploy tx `0xb24f4b52413b2b4e33593b23a64464525c5a158f70af94646e3cc215cb5fa294`, block 10153825, status 1) |

The v1 devnet deployment (`0x32b60D0fA270a2148dBD3386123b1979b15D0814`,
holding 2.5 test QOR) was superseded by the post-run revision; see
[`devnet/RUN_LOG.md`](devnet/RUN_LOG.md) for the full v1 E2E (including a
real ML-DSA-87 signature accepted by the live precompile, and a tampered
signature rejected by it).

## How it works

### The vault

- `deposit()` (payable, anyone) — plain transfers are accepted as deposits
  too (`receive()`).
- `queueWithdrawal(to, amount, pqSignature)` (owner only) — above
  `pqThreshold`, `pqSignature` must be a valid ML-DSA-87 signature by the
  owner over the message below; below the threshold it is ignored.
- `executeWithdrawal(id)` (owner only, after the timelock, within the daily
  limit) — the **only** function that moves funds out. Checks-effects-
  interactions + a reentrancy guard.
- `cancelWithdrawal(id)` (guardian or owner) — funds stay in the vault.
- `setGuardian(newGuardian)` (owner only) — `address(0)` removes the
  guardian.

Events: `Deposited`, `WithdrawalQueued`, `WithdrawalExecuted`,
`WithdrawalCancelled`, `GuardianChanged`.

### The PQ message scheme

The owner signs exactly these 32 bytes with their ML-DSA-87 secret key:

```
message = keccak256(abi.encode(
    "PQTimelockVault.withdrawal.v1",
    block.chainid,
    address(this),      // the vault
    withdrawalId,       // next queue id = queuedCount()
    to,                 // recipient
    amount,             // wei
    pqNonce             // current one-time nonce
))
```

Read it from the chain with the public view `pqMessageHash(id, to, amount,
nonce)` (the dApp shows it with a Copy button). The signature binds the
chain, the vault, the queue id, the recipient, the amount and a one-time
nonce, so it cannot replay anywhere else. `pqNonce` increments on every
above-threshold queue.

On-chain verification (`_verifyOwnerPQSignature`) requires, in order:

1. signature length exactly 4,627 bytes (ML-DSA-87);
2. the owner's key is **registered** (`pqcKeyStatus`);
3. `algorithmId == 1` (ML-DSA-87);
4. **`possessionProven == true`** — the chain's own docs require this:
   anyone can register someone else's public key for their own account, so
   without the possession proof a copied key would let one address pass as
   another;
5. public-key length exactly 2,592 bytes;
6. `pqcVerify(pubkey, signature, message) == true`.

It fails closed: on a network where the precompiles are inactive, the
high-level call reverts (no code at the precompile address), so an
above-threshold queue cannot succeed without real verification.

### Precompile interface (verified, not assumed)

Verified 2026-11-16 from three public sources before the contract was
written — docs.qorechain.io EVM Guide, the `@qorechain/evm` 0.12.0 npm
package (`IQORE_PQC_ABI`), and the public repo
github.com/qorechain/qorechain-core (`docs/EVM_PRECOMPILES.md` +
`x/vm/precompiles/`) — and validated live with `cast call` against the
testnet and the devnet:

| Precompile | Address | Signature |
|---|---|---|
| `pqcVerify` | `0x0000000000000000000000000000000000000A01` | `pqcVerify(bytes pubkey, bytes signature, bytes message) view returns (bool valid)` — gas 25,000 + 8/byte; returns `false` (never reverts) on invalid input |
| `pqcKeyStatus` | `0x0000000000000000000000000000000000000A02` | `pqcKeyStatus(address account) view returns (bool registered, uint8 algorithmId, bytes pubkey, bool possessionProven)` — gas 2,500 flat; the 4th output exists since v3.2.4 |

Note: the `IQORE_PQC_ABI` in `@qorechain/evm` 0.12.0 still shows the older
3-output `pqcKeyStatus`; the chain's repo docs say a caller decoding 3
outputs still reads the first three unchanged. This contract uses the
4-output interface.

## Repository layout

```
dapp-vault/
├── SPEC.md                 # behavior specification this entry was built from
├── README.md               # this file
├── AI_USAGE.md             # honest AI-native workflow (Best AI-Native Build)
├── AUDIT.md                # QCAI audit preparation + checklist
├── LICENSE                 # MIT
├── contracts/              # Foundry project
│   ├── src/PQTimelockVault.sol
│   ├── test/               # 44 unit tests + 2 fork tests
│   ├── script/Deploy.s.sol # forge deploy script (env-driven, no secrets)
│   └── flattened/          # flattened source for the QCAI audit paste
├── app/qore-vault-app/     # Vite + React + wagmi + RainbowKit + QoreX dApp
├── scripts/                # offline ML-DSA-87 signing helper (operator tooling)
└── devnet/                 # gov proposal JSON + full run log with tx hashes
```

## Frontend

```sh
cd app/qore-vault-app
npm install
cp .env.example .env   # set VITE_VAULT_ADDRESS (and VITE_EVM_RPC_URL for devnet)
npm run build          # must exit 0
npm run dev            # http://localhost:5173
```

The dApp: connect with QoreX (RainbowKit), deposit, queue withdrawals
(above-threshold: shows the owner's live PQC key status from the `0x0A02`
precompile, the exact message hash to sign, and a signature field), a queue
list with timelock countdowns and Execute/Cancel buttons, guardian
management, and a daily-limit panel. It also shows the account's EVM
authorisation window status and explains — honestly — that the window must
be opened on the native lane (the app cannot open it).

**The browser cannot sign ML-DSA-87.** Above-threshold withdrawals are
signed off-chain (see below) and pasted as a signature. The dApp never asks
for a private key, seed phrase, or mnemonic — and never will.

## Signing a withdrawal (above-threshold flow)

1. In the dApp, fill in recipient + amount above the PQ threshold. The form
   shows the 32-byte message hash (and the owner's PQC key status).
2. Sign the hash offline with your own PQC key:
   ```sh
   cd scripts
   npm install
   node sign-withdrawal.cjs /path/to/<name>.dilithium <message-hash-hex> [<pubkey-hex>]
   ```
   The script prints the 4,627-byte signature (and an offline verification
   result when given the pubkey). The secret key is read into memory only
   and never written anywhere by the script.
3. Paste the **signature** into the dApp form and queue the withdrawal.

## Tests

```sh
cd contracts
forge build        # 0 warnings
forge test         # 46/46 pass (44 unit + 2 fork)
forge test --match-contract PQTimelockVaultForkTest \
  --fork-url https://evm-testnet.qore.host   # 2/2 pass
```

Unit tests use a strict mock of both precompiles (etched with `vm.etch` at
`0x0A01`/`0x0A02`): `pqcVerify` returns true only when the pubkey, the
signature and the message each hash to the configured expected values, so a
signature made for a different message, amount, recipient or nonce is
rejected — the same binding real ML-DSA-87 verification gives. Coverage:
deposit, queue (below/above threshold, all key-status failure modes,
wrong-length keys/signatures, tampered signatures, nonce binding), timelock
(early execute reverts, exact-boundary execute), daily limit (block,
24h rollover, partial window, exact boundary), guardian cancel (guardian,
owner, non-guardian revert, cancel of executed entry), reentrancy attack,
insufficient-balance execute, guardian management, and all views.

**Fork-test limitation (honest):** Foundry's fork uses revm, which does not
implement QoreChain's custom precompiles, so the fork tests cannot exercise
the real `pqcVerify` path — they prove the below-threshold flow on real
testnet state and that the above-threshold path fails closed on a chain
without the precompiles. The real precompile path is proven instead by live
`eth_call` validation (testnet + devnet) and by the devnet E2E, where a real
ML-DSA-87 signature was accepted and a tampered one rejected by the live
precompile. See [`devnet/RUN_LOG.md`](devnet/RUN_LOG.md).

## Deploy

### Devnet

```sh
cd contracts
# The deployer needs: a registered ML-DSA-87 key, an open EVM window, and a
# UNIFIED eth-native account (eth_secp256k1) — see "SPEC corrections" below.
VAULT_OWNER=0x1A79... VAULT_GUARDIAN=0xd40C... VAULT_TIMELOCK=60 \
  forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
  --private-key $KEY --gas-limit 3000000 --broadcast
```

Notes from the real deploys: `forge create`/`cast send` need an explicit
`--gas-limit` on this devnet (gas estimation fails with `insufficient funds
for transfer`); receipts report `gasUsed` as exactly half the submitted gas
limit on every transaction (a devnet metering quirk — transactions execute
correctly and balances move by the exact expected amounts).

### Deploy to testnet — DONE 16 Nov 2026

1. Fund a **unified** testnet account (eth-native, `eth_secp256k1`) with
   testnet QOR.
2. Register its ML-DSA-87 key and open an EVM window on the native lane:
   `qorechaind tx pqc register-key-v2 …`, then
   `qorechaind tx pqc open-evm-window …` (wait ~10s after opening — the
   nonce advances).
3. Deploy with the production parameters (timelock 86400 = 24h, threshold
   1 QOR, daily limit 5 QOR):
   ```sh
   VAULT_OWNER=<owner> VAULT_GUARDIAN=<guardian> \
     forge script script/Deploy.s.sol --rpc-url https://evm-testnet.qore.host \
     --private-key $KEY --gas-limit 3000000 --broadcast
   ```
4. Point the dApp at it: `VITE_VAULT_ADDRESS=<new address>` in
   `app/qore-vault-app/.env`.

Testnet deployment (16 Nov 2026): vault
`0x2dd1d8b68da66948dd34f0efaab1edc87440e533` (5,378 bytes code; deploy tx
`0xb24f4b52413b2b4e33593b23a64464525c5a158f70af94646e3cc215cb5fa294`,
block 10153825, status 1). E2E verified on testnet: deposit 2 QOR status 1;
queue 1.5 QOR with a real ML-DSA signature status 1
(`0xa033fb1c4f527ef22e772882beee57e8e71410e075628a8db5f6cfcc80b5b93f`);
fake signature status 0
(`0xb2e4ee6e4c005b339cf8454f79f47b559fb635f8b501363950e178c1dda8ddb2`);
below-threshold queue status 1; guardian cancel status 1; execute before
the 24h timelock status 0 (timelock enforced). A successful post-timelock
execute was proven on the devnet (60s timelock) and cannot be re-tested in
one session on testnet (24h timelock). Full evidence:
`../TESTNET-DEPLOY-LOG.md`.

## SPEC corrections discovered by experiment

The behavior SPEC was written before these facts were known; each was
proven on the devnet and the SPEC's assumptions corrected here:

1. **The devnet's PQC precompiles were inactive** (`active_static_precompiles:
   []` in genesis). They were activated by governance proposal 25
   (`MsgUpdateParams`, passed with the validator's YES vote; see
   [`devnet/proposal-activate-pqc-precompiles.json`](devnet/proposal-activate-pqc-precompiles.json)
   and the run log). The testnet has them active.
2. **Plain Cosmos keys cannot send EVM transactions.** The SPEC assumed a
   devnet account's EVM address equals its bech32 bytes; that holds only
   for unified `eth_secp256k1` accounts. Plain `secp256k1` keys (e.g.
   `dv-owner`) have a different EVM sender (`keccak256(pubkey)[12:]`) than
   their bech32 address (`ripemd160(sha256(pubkey))`), and the EVM sender
   holds no funds and can never hold a PQC key or window. The E2E used the
   pre-existing unified accounts `evmtest` (owner) and `ewe` (guardian).
   ~~The CLI cannot create eth-native keys (`--key-type eth_secp256k1` is
   rejected).~~ **CORRECTED 16 Nov 2026 (testnet deploy):** the CLI *can*
   create eth-native keys with binary v3.2.7 — `keys add --key-type
   eth_secp256k1 --coin-type 60` succeeds (the testnet deployer/guardian/
   agent/bob accounts were all created this way).
3. **Minimum native fee is 60,000 uqor**, not 50,000 as the SPEC said (a
   50,000-uqor fee was rejected at CheckTx, code 13).
4. **`qorechaind tx` without `--yes` hangs** on the confirmation prompt in a
   non-TTY environment; always use `--yes` and `< /dev/null`.
5. **`tx pqc cosign` needs an explicit `--chain-id`** — the node home's
   `client.toml` has `chain-id = ""`, and without the flag cosign signs
   over the wrong chain-id, failing CheckTx with code 21 (`PQC signature
   verification failed`). The key files were proven correct; the chain-id
   was the bug.
6. **A code-0 broadcast is not a confirmation.** During this build the
   devnet froze for ~18 minutes (transient state.db I/O error, consensus
   panic, height stuck at 12697) while RPC/CheckTx kept answering; a
   broadcast that returned code 0 was never committed (mempool does not
   survive the restart that fixed it). Always verify with `query tx` and a
   state read.

## Known limitations

- **Testnet deployment DONE 16 Nov 2026** (vault
  `0x2dd1d8b68da66948dd34f0efaab1edc87440e533`, E2E verified — see Deploy to
  testnet above). A successful post-timelock execute cannot be tested in
  one session (24h timelock); it was proven on the devnet.
- **Browser PQ signing is unavailable** — above-threshold queues need the
  off-browser signing flow (SDK/CLI). The UI says so honestly.
- **Fork tests cannot exercise the real precompiles** (revm limitation);
  the real path is proven on the devnet instead (see Tests).
- **QCAI audit not run** — artifacts are ready (flattened source +
  [`AUDIT.md`](AUDIT.md)); execution needs the user's Dashboard sign-in.
- The devnet is shared with other agents; proposal 26 in the gov queue
  belongs to another agent and was left alone.

## License

MIT — see [LICENSE](LICENSE).
