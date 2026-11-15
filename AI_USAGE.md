# AI Usage — PQ Timelock Vault

Honest account of how AI was used to build this entry, for the **Best
AI-Native Build** award ($500). Nothing here is hidden; the workflow below
is the actual one.

## What the AI did

An AI agent (Muse, Meta's personal AI agent) built this entry end-to-end
from a written behavior specification (`SPEC.md`), in a **fresh-write**
workflow:

1. **Precompile verification first.** Before writing any contract code, the
   agent verified the PQC precompile addresses and ABIs from three public
   sources (docs.qorechain.io, the `@qorechain/evm` npm package, and the
   public `qorechain-core` repo), then validated them live with `cast call`
   against the testnet. No ABI was invented.
2. **Contract from the SPEC, not from copied code.** The agent wrote
   `PQTimelockVault.sol` from the behavior specification alone — it was
   explicitly forbidden from reading other entries, audit notes, or existing
   implementations. Design decisions (the PQ message scheme, the rolling
   24h window with a pruning pointer, the fail-closed verification order)
   are the agent's own, documented in the contract's NatSpec and the README.
3. **Tests written alongside the contract.** 44 Foundry unit tests
   (including a strict precompile mock) and 2 fork tests, all written by the
   agent and run for real — 46/46 pass.
4. **Devnet E2E driven by the agent.** The agent operated the local devnet
   itself: diagnosed the inactive precompiles and activated them by
   governance proposal, registered PQC keys, opened EVM windows, deployed
   the vault, and ran the full deposit → queue → timelock → execute →
   guardian-cancel flow plus a real ML-DSA-87 signature round-trip against
   the live precompile. Every transaction hash in `devnet/RUN_LOG.md` is
   from a real run.
5. **Frontend built on the official scaffold**, then replaced with the vault
   UI (deposit, queue with PQ-signing flow, countdown queue list, guardian
   and daily-limit panels).
6. **Mandatory revision loop.** After the first working run, the agent
   revised the contract (modifier reorder, lint clean-up to zero warnings,
   a new unit test for the insufficient-balance execute path), re-ran all
   tests, redeployed to the devnet, and re-ran the E2E smoke against the new
   deployment.

## What the AI did NOT do

- It did not copy code from other hackathon entries, from audit notes, or
  from any existing vault implementation (reading those was forbidden by
  the task rules).
- It did not invent test results: every claim in the README and run log
  comes from a real command run, and the limitations section lists what
  could not be done (no testnet deployment, no QCAI audit run, fork tests
  cannot exercise the real precompiles).
- It did not handle real funds or mainnet keys. All keys used were
  devnet-only test keys; no secret key, seed, or mnemonic was ever written
  to any file in this repository (private keys were used only as shell
  variables during deploys, never printed or stored).
- It did not run the QCAI audit — that needs the human's Dashboard
  sign-in, so the agent prepared the artifacts and left execution as a
  human step (see `AUDIT.md`).

## Where the human was in the loop

- The human (Bayu Agustian) wrote the task and the behavior specification,
  set the hard rules (fresh-write, testnet/devnet only, no invented
  results, mandatory revision), and owns the devnet, the wallets, and the
  Dashboard account.
- The agent worked autonomously within those rules and reported back to a
  coordinator agent with a full handoff (test commands + results, tx
  hashes, limitations, and what needs human action).
- Human action still needed: testnet deployment funding, the QCAI audit
  run, and the final hackathon submission.

## AI-native, not AI-only

The point of this workflow is leverage, not replacement: the human defined
*what* to build and the constraints; the AI did the implementation,
verification, and honest documentation — including the parts where reality
disagreed with the spec (inactive precompiles, plain-vs-unified accounts,
the 60,000-uqor minimum fee, the missing `--chain-id` in cosign, the
devnet freeze). Those corrections are recorded in the README and the run
log rather than papered over, because an AI-native build should be judged
on its evidence, not its claims.
