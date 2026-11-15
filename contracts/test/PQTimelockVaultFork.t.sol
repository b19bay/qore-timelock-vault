// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PQTimelockVault} from "../src/PQTimelockVault.sol";

/// @notice Fork tests against the QoreChain testnet (qorechain-diana, 9800).
///         Run explicitly: `forge test --match-contract PQTimelockVaultForkTest
///         --fork-url https://evm-testnet.qore.host`
///
///         HONEST SCOPE — what a Foundry fork can and cannot prove here:
///         Foundry replays fork state in revm, which does NOT implement
///         QoreChain's custom precompiles (0x0A01 / 0x0A02 are node-level Go
///         code, not contracts with bytecode). In a fork those addresses hold
///         no code, so a high-level call to them reverts with no data. Direct
///         fork tests of the real precompiles are therefore IMPOSSIBLE with
///         Foundry; do not add them — they fail for environmental reasons,
///         not contract reasons (verified 2026-11-16: both direct calls
///         reverted `EvmError: Revert` at fork block 10,147,900).
///
///         The real precompiles were instead validated with LIVE eth_call
///         queries against the testnet RPC (2026-11-16, all returned as the
///         chain docs specify):
///           cast call --rpc-url https://evm-testnet.qore.host \
///             0x0000000000000000000000000000000000000a02 \
///             "pqcKeyStatus(address)(bool,uint8,bytes,bool)" \
///             0x1234567890123456789012345678901234567890
///             -> false, 0, 0x, false   (unregistered account; 4-output ABI ok)
///           cast call --rpc-url https://evm-testnet.qore.host \
///             0x0000000000000000000000000000000000000a01 \
///             "pqcVerify(bytes,bytes,bytes)(bool)" <2592B key> <4627B sig> 0x68656c6c6f
///             -> false                 (garbage inputs return false, no revert)
///           same with wrong sizes -> false
///
///         What THIS file proves on the fork:
///          - The vault deploys and runs its below-threshold flow on real
///            testnet state.
///          - The above-threshold path FAILS CLOSED when the precompiles are
///            absent (the fork models a node without them): the queue reverts
///            instead of succeeding without verification.
///
///         The positive above-threshold path with a REAL ML-DSA-87 signature
///         needs a testnet account with a registered key AND its PQC secret
///         key; no such testnet key is available to this run. It is covered
///         by the strict mock tests (unit suite) and by the devnet E2E run
///         where the test accounts are controlled.
contract PQTimelockVaultForkTest is Test {
    address internal owner = makeAddr("fork-owner");
    address internal guardian = makeAddr("fork-guardian");
    address internal recipient = makeAddr("fork-recipient");

    function testFork_VaultBelowThresholdFlowOnRealState() public {
        PQTimelockVault vault = new PQTimelockVault(owner, guardian, 60, 1 ether, 5 ether);
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vault.deposit{value: 5 ether}();
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + 61);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(recipient.balance, 0.5 ether);
    }

    function testFork_VaultFailsClosedAboveThreshold() public {
        PQTimelockVault vault = new PQTimelockVault(owner, guardian, 60, 1 ether, 5 ether);
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vault.deposit{value: 5 ether}();
        // In the fork, revm has no code at 0x0A02, so the high-level
        // pqcKeyStatus call reverts with NO data (not with our
        // "owner has no PQC key" string — that string only appears when the
        // real precompile answers). The queue must still revert: no
        // above-threshold withdrawal may succeed without real verification.
        bytes memory sig = new bytes(4627);
        vm.prank(owner);
        vm.expectRevert();
        vault.queueWithdrawal(recipient, 2 ether, sig);
        assertEq(vault.queuedCount(), 0);
    }
}
