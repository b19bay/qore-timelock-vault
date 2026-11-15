# QCAI Audit Preparation — PQ Timelock Vault

QoreChain's AI audit (QCAI) is a **2-stage** audit run from the QoreChain
Dashboard. This entry's audit artifacts are ready; the audit itself has
**NOT** been run — it needs the user's Dashboard sign-in, which the build
agent does not have. Do not claim otherwise.

## Artifacts ready

| Artifact | Location |
|---|---|
| Flattened contract source (paste into QCAI) | `contracts/flattened/PQTimelockVault.flattened.sol` (370 lines, single `pragma solidity ^0.8.28`, matches current source incl. the revision) |
| Contract source (structured) | `contracts/src/PQTimelockVault.sol` |
| Unit + fork tests | `contracts/test/` (46/46 pass; see README § Tests) |
| Devnet E2E evidence | `devnet/RUN_LOG.md` (deploy + all tx hashes, incl. real ML-DSA-87 accept/reject on the live precompile) |

Regenerate the flattened file after any contract change:

```sh
cd contracts
forge flatten src/PQTimelockVault.sol --output flattened/PQTimelockVault.flattened.sol
```

## How to run the audit (human step)

1. Sign in to the QoreChain Dashboard at `dashboard.qorechain.io`.
2. Open the audit flow (`dashboard.qorechain.io/audit`).
3. Paste the flattened source from
   `contracts/flattened/PQTimelockVault.flattened.sol`.
4. Run **stage 1**, then **stage 2** (the audit is 2-stage; run both).
5. The first audit of the day (UTC) is free; check the Dashboard for the
   current pricing of further audits.

## Checklist (to complete after the run)

- [ ] Stage 1 run — date/time, score, findings (list each).
- [ ] Stage 2 run — date/time, score, findings (list each).
- [ ] Response written for every finding (fixed / acknowledged with reason /
      false positive with evidence).
- [ ] Audit PDF/report saved (where? record the path).
- [ ] Any code changes from findings re-tested (`forge test`) and, if the
      bytecode changed, redeployed to the devnet and smoke-tested again.

## Notes for the auditor (context the flattened file does not carry)

- The contract calls QoreChain's PQC precompiles at `0x0A01`/`0x0A02`. On
  chains without them, above-threshold queues revert (fail-closed by
  design); the below-threshold flow works on any EVM chain.
- `address(0)` as guardian is intentional ("no guardian"); the owner can
  still cancel. `setGuardian(address(0))` is the documented removal path.
- `block.timestamp` is used for the timelock and the rolling 24h window by
  design; seconds of block-time skew are immaterial at these timescales.
- The reentrancy guard is a minimal in-contract `locked` flag (no external
  dependency); `executeWithdrawal` is the only function that moves funds
  out, and it applies effects before the external call.
- The rolling-window pruning pointer (`windowHead`) only moves forward;
  old execution records are skipped, never deleted, so `executionCount`
  grows by one per execution.
