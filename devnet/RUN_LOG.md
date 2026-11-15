# Devnet run log — PQTimelockVault E2E (2026-11-16)

Local devnet `qorechain-devnet` (EVM chain id 9800, JSON-RPC
`http://localhost:8545`, Cosmos RPC `tcp://localhost:26657`). All transactions
below are devnet-only test funds. No mainnet, no real funds.

## Current deployment (v2 — revised contract)

The v1 vault below was superseded after the mandatory post-run revision
(modifier reorder + lint clean-up; see "Revision" section). The current
deployment matches the current contract source.

| Item | Value |
|---|---|
| Vault contract (v2) | `0xb6c45e628188DD084879Bc0eEC2813d6c8Fd755D` |
| Deploy tx | `0xa0c9324872241ea2d5e6614798bdbbef631468e3193c8d6a95fed3a4d094d837` (block 12747, status 1, gasUsed 1,500,000) |
| Owner / guardian | same as v1 (`0x1A79…`, `0xd40C…`) |
| timelockSeconds / pqThreshold / dailyLimit | 60 / 1 QOR / 5 QOR |

### v2 smoke E2E (2026-11-16 ~02:0x WIB)

Recipient `0x8C12…` started at 12.5 QOR (from the v1 E2E).

| # | Step | Tx hash | Result |
|---|---|---|---|
| 1 | Deposit 1 QOR (owner) | `0x203d6e41f91a39afb3537b6fcf0d8f388cf5da2b6315928aa8d01c45ba23a9d0` | block 12764, status 1, `Deposited`; vault 1 QOR |
| 2 | Queue id 0: 0.5 QOR, empty sig (below threshold) | `0xcfe57a84805f015dc938306a9f84b9f4a4b17436e7ec9aa4ccf30f45ec231010` | block 12767, status 1, `WithdrawalQueued`; executeAfter = queuedAt + 60 |
| 3 | Execute id 0 after 70s | `0xef00c4d86069a999d411fa257accae2c6b632ca718511b12f80727b8175c7bc4` | block 12832, status 1, `WithdrawalExecuted`; recipient 12.5 → 13 QOR; vault 0.5 QOR; `withdrawnLast24h` 0.5 QOR; status Executed |

### Top-up for the redeploy

evmtest had 1,066,598 uqor left after the v1 E2E. ewe → evmtest
2,000,000 uqor: tx `03B1546555F40C0DA74AF83E6015C002A0C651B9757620FC356713F177DE93C3`,
height 12727, code 0, gas 186,848. evmtest → 3,066,598 uqor.

**Lesson — `cosign` needs an explicit `--chain-id`.** The first two
top-up attempts (dv-owner, then ewe) were CheckTx-rejected with code 21,
`PQC signature verification failed … hybrid PQC signature verification
failed`. The key files were PROVEN correct (offline: each secret key's
signature verifies against its registered on-chain pubkey). The real cause:
`client.toml` in the node home has `chain-id = ""`, and the cosign
commands did not pass `--chain-id`, so cosign signed over the wrong
chain-id. Re-running the identical unsigned tx with
`--chain-id qorechain-devnet` passed CheckTx (code 0). Always pass
`--chain-id` explicitly to `cosign` (and to `generate-only`).

**Incident — devnet froze 18:40 UTC (01:40 WIB), recovered 18:58 UTC.**
The chain stopped at height 12697: `CONSENSUS FAILURE!!!` in the node log,
`write …/data/state.db/000082.log: input/output error` — a transient disk
I/O error (disk was NOT full: 130G free, devnet data 163M; writes worked
again immediately). The node process stayed up (RPC answered, CheckTx still
passed) but consensus never recovered on its own. Recovery: clean SIGTERM
stop, restart with the same command line; CometBFT replayed the WAL and
resumed (height 12703 within 20s of restart, advancing normally). The
top-up tx above was first broadcast while frozen (code 0 at CheckTx but
never committed — mempool does not survive a restart); it was re-broadcast
after recovery and committed at height 12727. Lesson: a code-0 broadcast
is NOT a confirmation — always verify with `query tx` and a balance/state
read.

## Deployed vault (v1 — superseded by v2)

| Item | Value |
|---|---|
| Vault contract | `0x32b60D0fA270a2148dBD3386123b1979b15D0814` |
| Deploy tx | `0x6a02bf62874afb615dbfdbe8d6229440a7db3a1d8cec29118df949293692a9ae` (block 11999, status 1) |
| Owner | `0x1A79C62CB23E6813EF82929E25814822A8216776` (`evmtest`, `qor1rfuuvt9j8e5p8muzj20ztq2gy25zzemk3us2q2`) |
| Guardian | `0xd40Ca79AB4f3c02DAe2f64C97e1C5E48dD09aCD5` (`ewe`, `qor16sx20x4570qzmt30vnyhu8z7frwsntx4aznq7a`) |
| timelockSeconds | 60 |
| pqThreshold | 1 QOR (10^18 wei) |
| dailyLimit | 5 QOR / 24h rolling |
| Negative-test actor | `0xc8Ea6FAC61DDe322edf955e04a6Cd03910F3b161` (`ewe2`, `qor1er4xltrpmh3j9m0e2hsy5mxs8yg08vtpkvqjyf`) |
| E2E recipient | `0x8C12E20EA72E1C8AB657D343A23737E6ED3A3877` (dv-attacker bech32 bytes) |

## Why the owner is `evmtest`, not `dv-owner` (SPEC correction, proven)

The SPEC assumed the devnet accounts' EVM address equals their bech32 bytes.
That holds only for **unified eth-native accounts** (`eth_secp256k1`). The
`dv-owner` / `dv-guardian` / `dv-attacker` keys are plain Cosmos `secp256k1`
keys: their bech32 address is `ripemd160(sha256(pubkey))` while their EVM
sender is `keccak256(pubkey)[12:]` — different 20 bytes. Proof:

- `dv-owner` bech32 bytes: `0x1E16881E62A6BF953C32B80D54D643A2B636F3EE`
- `dv-owner` EVM sender from its private key (`cast wallet address`):
  `0xAa584E97EfE56f38293FD8C55A095283f8C9FFf9`
- Deploy from `dv-owner` failed: `sender balance < tx cost (0 < ...)` — the
  keccak-derived account holds no funds and can never hold a PQC key or a
  window (native messages sign as the ripemd identity).
- `qorechaind keys add --key-type eth_secp256k1` (and `ethsecp256k1`) are
  rejected by this CLI build, so no fresh unified account could be created
  in the keyring.

The keyring already holds three unified accounts (`evmtest`, `ewe`, `ewe2`,
pubkey type `/cosmos.evm.crypto.v1.ethsecp256k1.PubKey`); their bech32 bytes
were verified to equal their EVM addresses (`debug addr` vs
`cast wallet address`). The E2E uses `evmtest` (owner) and `ewe` (guardian).
`dv-owner` / `dv-guardian` were still used for the PQC-registration and
window-opening flows (both work — see below) and `dv-owner` funded `evmtest`.

## Setup (native txs, all DeliverTx code 0 unless noted)

| Step | Tx hash | Notes |
|---|---|---|
| Register PQC key, dv-owner | `8FFCB64DA14AE9B8A6C22BDDB9E364ECD79441FE3C7658FACFF9902D6680E21E` | height 11463, gas 275,964; algo 1, possession proven |
| Register PQC key, dv-guardian | `86CA332BA77D603563422B08D1063FBC025143966E4DA6AA480341FCFF51180A` | height 11485, gas 275,964; algo 1, possession proven |
| Gov proposal 25 (activate 0x0A01/0x0A02) | `00A62E8701D9C12D39A70D380A32C47284DFE4A5A1980EA0EFC59553904A9947` | height 11537, gas 318,369; `/cosmos.evm.vm.v1.MsgUpdateParams` |
| Vote YES, validator | `3E80C8FC7B6B0508A8331A5B9D8BC126BF87BB5CE19B112E8A9BAE42D43B0435` | height 11542, code 0 |
| Proposal 25 result | — | PASSED; tally yes `50000000000000`, no 0; `active_static_precompiles` now `['0x...0a01', '0x...0a02']` |
| Fund evmtest 5 QOR (from dv-owner) | `B0B82265393EFB1555904ABB2C8A6BF12BE4F826335034092D3DDA38A806B542` | gas 166,234; evmtest 1.571598 → 6.571598 QOR |
| Open EVM window, evmtest (3600 blocks, 20 txs, 25 QOR) | `7A09B3AB29A721FE4BAF98B0A84BEEEA5D1DCB906351213F58B29920C8B1626A` | gas 186,511; expiry 15561 |
| Open EVM window, ewe (3600 blocks, 10 txs, 25 QOR) | `C520CD49691AEF0EBE69720DDA6ACAA3AA9AA857230656973A9DAAEF6F74C015` | gas 186,319; expiry 15566 |
| Open EVM window, ewe2 (3600 blocks, 5 txs, 25 QOR) | `E950182DA6068B2AE10F95803AC668E5F1351AB3256020E32E22BD4F5EA05380` | code 0 |
| Open EVM window, dv-owner | `BB94790BA4F184A466BCC2EB1A06BF513EB3A9DC67C0C60D33114CAB040BF841` | gas 165,849 (flow proof; unused for EVM) |
| Open EVM window, dv-guardian | `D15FD115808845D949AF5AFDF350FDC81B15B53C053E55AC5AD6702DB5211C07` | gas 165,849 (flow proof; unused for EVM) |

Notes:

- The devnet started with `active_static_precompiles: []` — the PQC
  precompiles were INACTIVE (raw `eth_call` to 0x0A02 returned `0x`). They
  were activated by governance proposal 25 (30s voting period on this
  devnet; the validator key in the keyring voted YES). After activation, a
  live `eth_call` to `pqcKeyStatus` for dv-owner returned
  `(true, 1, <2592-byte key>, true)` — the 4-output ABI decodes on-chain.
- Minimum native fee on this devnet is **60,000 uqor**, not 50,000 as the
  SPEC assumed: a registration with `--fees 50000uqor` was rejected at
  CheckTx, code 13, `provided fee < minimum global fee (50000uqor <
  60000uqor)`. All later native txs used `--fees 100000uqor`.
- `qorechaind tx` without `--yes` hangs on a confirmation prompt when stdin
  is not a TTY in this environment; all tx commands used `--yes` and
  `< /dev/null`.
- The `.dilithium` key files hold the 4,896-byte ML-DSA-87 secret key as a
  9,792-character hex string (no header, no newline).

## E2E — EVM transactions

Recipient `0x8C12...` started at 10 QOR; vault started empty.

| # | Step | Tx hash | Result |
|---|---|---|---|
| 1 | Deposit 5 QOR (owner) | `0xee3f0bd4c46ef6d44a263295f8247ac62eac0a1775254d8074c15f481defb258` | block 12018, status 1, `Deposited`; vault 5 QOR |
| 2 | Queue id 0: 0.5 QOR, empty sig (below threshold) | `0xa75d1cfbb0889031bbd5299654d9d349322138fac6b434fb690b5ae4410ff1d5` | block 12021, status 1, `WithdrawalQueued`; executeAfter = queuedAt + 60 |
| 3 | Execute id 0 BEFORE timelock (negative) | `0x2bda0b56f9c9c22d471f181c03bc5794de08e01a086e456b5f2d859c1e110c1e` | status 0, revert `timelock not passed` |
| 4 | Execute id 0 after 70s | `0x578e3eff2481aca8610c5c00f87d73f9b3799d2597278256dddbe91f0795b328` | block 12090, status 1, `WithdrawalExecuted`; recipient 10 → 10.5 QOR; vault 4.5 QOR; `withdrawnLast24h` 0.5 QOR; status Executed |
| 5 | Queue id 1: 0.5 QOR (owner) | `0x72d982fb5e14454fc3c07afb0454d142ee2ca1914dbbcdc93b067507ce1592f0` | status 1 |
| 6 | Cancel id 1 by ewe2, not guardian (negative) | `0xc0e3f78e121b6106ebaf7b45790fb22eb275c6b9d09954b0dbd98646b3eccb70` | status 0, revert `not guardian or owner` |
| 7 | Cancel id 1 by guardian ewe | `0xaf6b47ce77806b08821a9eaefee1bbfb29b95b02729f44929bf26b344a9f2e97` | block 12132, status 1, `WithdrawalCancelled`; status Cancelled; vault still 4.5 QOR; recipient still 10.5 QOR |
| 8 | Execute cancelled id 1 (negative) | `0xf5106022be662bd5b6f3e53f84a878938a4fc5ec4b99524eafe42a5bafb0e2ed` | status 0, revert `not queued` |
| 9 | Queue id 2: 2 QOR with TAMPERED PQ sig (negative) | `0xfaeae48e539fb0a4eeeeb221539fc1b99976afade06fd5eda0893289e6fdf5d9` | status 0, revert `invalid PQ signature` (real precompile rejected it) |
| 10 | Queue id 2: 2 QOR with REAL ML-DSA-87 sig | `0xe08fd9d36c8fb40f98b1360395615ca0fd20520d141b7223b3e07f66e7e9ffce` | block 12406, status 1, `WithdrawalQueued`; `pqNonce` 0 → 1 |
| 11 | Execute id 2 after 70s | `0x472f9868af43c5c573eb483b2f4921e1a47187b313eebd9b17dda63fb8779755` | block 12474, status 1, `WithdrawalExecuted`; recipient 10.5 → 12.5 QOR; vault 2.5 QOR; `withdrawnLast24h` 2.5 QOR; status Executed |

The real PQ signature (step 10) was produced offline with
`@qorechain/sdk` 0.13.0 `pqcSign` over the vault's `pqMessageHash(2, to,
2 QOR, nonce 0)` = `0xd59cb9e67f27df915be78d3b5ddaee6d6d048cf5758e97ef5afe83fb0d7e5ccc`,
using the evmtest ML-DSA-87 secret key, and verified offline with
`pqcVerify` against the key the chain holds for evmtest (`true`) before the
transaction was sent. The contract's on-chain `pqcVerify` call against the
live precompile then accepted it, and the tampered variant (step 9) was
rejected — the full post-quantum path is proven on a live chain.

## Chain quirks observed (devnet)

- `eth_estimateGas` / forge gas estimation is unreliable on this devnet
  (deploy without an explicit gas limit failed with `insufficient funds for
  transfer`); all EVM sends used explicit `--gas-limit` (3,000,000 deploy,
  500,000 calls, 800,000 for the PQ queue).
- Receipt `gasUsed` reads exactly half the submitted gas limit on every
  transaction (1,500,000 of 3,000,000; 250,000 of 500,000; 400,000 of
  800,000). Transactions still execute correctly; the figure looks like a
  devnet metering/reporting quirk, not a billing error (balances moved by
  the exact expected amounts).
- `cast call` to a precompile address fails client-side (`contract ... does
  not have any code`) because precompiles carry no bytecode; raw `eth_call`
  via curl works.
- The devnet node died during a VM service restart mid-session and was
  restarted with the same command line (`qorechaind start --home
  .../devnet/node1`); state survived (height continued from ~11,139).
- The devnet node froze a second time (18:40 UTC, height 12697) on a
  transient state.db I/O error; recovered by clean restart (see "Incident"
  above). The node runs detached (`setsid nohup …`); check liveness with
  `/status` height advancing, not just process existence.

## Revision (mandatory post-run revision, SPEC §5)

After the first working run (v1 E2E complete), the contract and tests were
revised and everything re-run:

1. `executeWithdrawal` modifiers reordered to `nonReentrant onlyOwner`
   (fixes the `non-reentrant-not-first` linter warning; the guard is now
   set before any other check).
2. All other `forge build` linter warnings resolved with justification:
   `missing-zero-check` on `_guardian` / `setGuardian` (address(0) is the
   documented "no guardian" value); `reentrancy-eth` and
   `reentrancy-events` on the transfer (guard set + effects first, so
   reentrancy is impossible); `block-timestamp` in the timelock and the
   rolling-window checks (a timelock/window IS a timestamp comparison;
   seconds of skew are immaterial). Each suppression is a
   `forge-lint: disable-next-line(...)` comment directly above the flagged
   line with the reason.
3. New unit test `testExecuteInsufficientVaultBalanceReverts`: two queues
   that each pass the queue-time balance check but sum above the balance —
   the second execute reverts `insufficient vault balance`, stays Queued,
   and executes after a top-up.
4. Two daily-limit tests rewritten to track time in a local `t0` instead of
   re-reading `block.timestamp` after `vm.warp` (fixes
   `environment-read-across-mutation` warnings).

Result: `forge build` — **0 warnings**; `forge test` — **46/46 pass**
(44 unit + 2 fork); fork tests with `--fork-url
https://evm-testnet.qore.host` — **2/2 pass**. Because the bytecode changed
(modifier reorder), the vault was redeployed as v2 (above) and the smoke
E2E re-run against it.
