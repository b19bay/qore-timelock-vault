// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PQTimelockVault} from "../src/PQTimelockVault.sol";

/// @notice Mock of QoreChain's PQC precompiles (0x0A01 / 0x0A02), etched onto
///         the real precompile addresses with `vm.etch` in tests.
///
///         The mock is STATELESS: all behaviour is baked into immutables, which
///         live in the runtime bytecode, so `vm.etch` preserves them (etched
///         code has no storage of its own). One mock contract implements both
///         precompile functions and is etched at both addresses; dispatch is
///         by function selector, exactly as on-chain.
///
///         `pqcVerify` is strict: it returns true only when the pubkey, the
///         signature and the message each hash to the configured expected
///         values. A signature made for a different message, amount,
///         recipient or nonce is rejected — the same binding the real
///         ML-DSA-87 verification gives.
contract MockPQC {
    bool internal immutable REG;
    uint8 internal immutable ALGO;
    bool internal immutable PROVEN;
    bytes32 internal immutable SIG_HASH;
    bytes32 internal immutable MSG_HASH;
    bytes32 internal immutable PK_HASH;

    constructor(
        bool reg,
        uint8 algo,
        bool proven,
        bytes32 sigHash,
        bytes32 msgHash,
        bytes32 pkHash
    ) {
        REG = reg;
        ALGO = algo;
        PROVEN = proven;
        SIG_HASH = sigHash;
        MSG_HASH = msgHash;
        PK_HASH = pkHash;
    }

    /// @dev The mock owner's key: 2,592 bytes of 0x11 (the real ML-DSA-87
    ///      public-key length). Tests build the same bytes to hash them.
    function fixedPubkey() public pure returns (bytes memory pk) {
        pk = new bytes(2592);
        for (uint256 i; i < 2592; ++i) {
            pk[i] = 0x11;
        }
    }

    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        view
        returns (bool)
    {
        return keccak256(pubkey) == PK_HASH && keccak256(signature) == SIG_HASH
            && keccak256(message) == MSG_HASH;
    }

    function pqcKeyStatus(address)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool possessionProven)
    {
        return (REG, ALGO, fixedPubkey(), PROVEN);
    }
}

/// @notice Malicious recipient: tries to re-enter `executeWithdrawal` from its
///         receive function, for the same id and for a second queued id.
contract ReentrantAttacker {
    PQTimelockVault public vault;
    uint256 public id;
    uint256 public otherId;
    uint256 public reenterAttempts;

    constructor(PQTimelockVault _vault, uint256 _id, uint256 _otherId) {
        vault = _vault;
        id = _id;
        otherId = _otherId;
    }

    receive() external payable {
        ++reenterAttempts;
        try vault.executeWithdrawal(id) {} catch {}
        try vault.executeWithdrawal(otherId) {} catch {}
    }
}

contract PQTimelockVaultTest is Test {
    address internal constant PQC_VERIFY_ADDR = address(uint160(0x0A01));
    address internal constant PQC_KEY_STATUS_ADDR = address(uint160(0x0A02));

    uint256 internal constant TIMELOCK = 1 days;
    uint256 internal constant PQ_THRESHOLD = 1 ether;
    uint256 internal constant DAILY_LIMIT = 5 ether;

    PQTimelockVault internal vault;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");
    address internal recipient = makeAddr("recipient");

    event Deposited(address indexed from, uint256 amount);
    event WithdrawalQueued(uint256 indexed id, address indexed to, uint256 amount, uint256 executeAfter);
    event WithdrawalExecuted(uint256 indexed id, address indexed to, uint256 amount);
    event WithdrawalCancelled(uint256 indexed id, address indexed by);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);

    function setUp() public {
        vault = new PQTimelockVault(owner, guardian, TIMELOCK, PQ_THRESHOLD, DAILY_LIMIT);
        vm.deal(owner, 100 ether);
        vm.deal(attacker, 10 ether);
        // Fund the vault with 20 QOR.
        vm.prank(owner);
        vault.deposit{value: 20 ether}();
    }

    /// @dev Redeploy the vault with custom threshold/limit (e.g. daily-limit
    ///      tests use a high PQ threshold so the PQ path is not in play).
    function _redeployVault(uint256 threshold, uint256 limit) internal {
        vault = new PQTimelockVault(owner, guardian, TIMELOCK, threshold, limit);
        vm.prank(owner);
        vault.deposit{value: 20 ether}();
    }

    // ------------------------------------------------------------------------
    // Mock helpers
    // ------------------------------------------------------------------------

    function _fixedPubkey() internal pure returns (bytes memory pk) {
        pk = new bytes(2592);
        for (uint256 i; i < 2592; ++i) {
            pk[i] = 0x11;
        }
    }

    /// @dev A deterministic 4,627-byte "signature" (real ML-DSA-87 length).
    function _makeSig(bytes1 marker) internal pure returns (bytes memory sig) {
        sig = new bytes(4627);
        sig[0] = marker;
        sig[4626] = marker;
    }

    /// @dev Etch a mock at both precompile addresses. `validSig`/`validMsg`
    ///      are the exact bytes pqcVerify must accept (pass empty bytes to
    ///      accept nothing).
    function _etchMock(
        bool reg,
        uint8 algo,
        bool proven,
        bytes memory validSig,
        bytes memory validMsg
    ) internal {
        MockPQC mock = new MockPQC(
            reg, algo, proven, keccak256(validSig), keccak256(validMsg), keccak256(_fixedPubkey())
        );
        vm.etch(PQC_VERIFY_ADDR, address(mock).code);
        vm.etch(PQC_KEY_STATUS_ADDR, address(mock).code);
    }

    /// @dev The exact message bytes the vault passes to pqcVerify for a queue.
    function _vaultMessage(uint256 id, address to, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(vault.pqMessageHash(id, to, amount, nonce));
    }

    /// @dev Queue an above-threshold withdrawal with a mock-valid signature.
    function _queueAboveThreshold(address to, uint256 amount) internal returns (uint256 id) {
        id = vault.queuedCount();
        bytes memory sig = _makeSig(0x42);
        bytes memory msgBytes = _vaultMessage(id, to, amount, vault.pqNonce());
        _etchMock(true, 1, true, sig, msgBytes);
        vm.prank(owner);
        return vault.queueWithdrawal(to, amount, sig);
    }

    // ------------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------------

    function testDepositAddsBalanceAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(attacker, 3 ether);
        vm.prank(attacker);
        vault.deposit{value: 3 ether}();
        assertEq(vault.balance(), 23 ether);
    }

    function testReceiveAcceptsPlainTransfer() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(attacker, 1 ether);
        vm.prank(attacker);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.balance(), 21 ether);
    }

    function testDepositZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert("zero deposit");
        vault.deposit{value: 0}();
    }

    // ------------------------------------------------------------------------
    // Queue: below threshold
    // ------------------------------------------------------------------------

    function testQueueBelowThresholdWithoutSig() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalQueued(0, recipient, 0.5 ether, block.timestamp + TIMELOCK);
        vm.prank(owner);
        uint256 id = vault.queueWithdrawal(recipient, 0.5 ether, "");
        assertEq(id, 0);
        assertEq(vault.queuedCount(), 1);
        (address to, uint256 amount, uint256 queuedAt, uint256 executeAfter, PQTimelockVault.Status status) =
            vault.getWithdrawal(0);
        assertEq(to, recipient);
        assertEq(amount, 0.5 ether);
        assertEq(queuedAt, block.timestamp);
        assertEq(executeAfter, block.timestamp + TIMELOCK);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Queued));
        // Below-threshold queues do not consume the PQ nonce.
        assertEq(vault.pqNonce(), 0);
    }

    function testQueueAtExactlyThresholdNeedsNoSig() public {
        // The threshold binds only amounts STRICTLY above it.
        vm.prank(owner);
        vault.queueWithdrawal(recipient, PQ_THRESHOLD, "");
        assertEq(vault.queuedCount(), 1);
    }

    function testQueueByNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert("not owner");
        vault.queueWithdrawal(recipient, 0.5 ether, "");
    }

    function testQueueExceedingBalanceReverts() public {
        vm.prank(owner);
        vm.expectRevert("exceeds vault balance");
        vault.queueWithdrawal(recipient, 21 ether, "");
    }

    function testQueueZeroAmountReverts() public {
        vm.prank(owner);
        vm.expectRevert("zero amount");
        vault.queueWithdrawal(recipient, 0, "");
    }

    function testQueueZeroRecipientReverts() public {
        vm.prank(owner);
        vm.expectRevert("recipient is zero");
        vault.queueWithdrawal(address(0), 0.5 ether, "");
    }

    // ------------------------------------------------------------------------
    // Queue: above threshold (PQ path)
    // ------------------------------------------------------------------------

    function testQueueAboveThresholdValidSig() public {
        uint256 id = _queueAboveThreshold(recipient, 2 ether);
        assertEq(id, 0);
        assertEq(vault.queuedCount(), 1);
        assertEq(vault.pqNonce(), 1);
    }

    function testQueueAboveThresholdNoSigReverts() public {
        vm.prank(owner);
        vm.expectRevert("bad PQ signature length");
        vault.queueWithdrawal(recipient, 2 ether, "");
    }

    function testQueueAboveThresholdWrongLengthSigReverts() public {
        vm.prank(owner);
        vm.expectRevert("bad PQ signature length");
        vault.queueWithdrawal(recipient, 2 ether, new bytes(100));
    }

    function testQueueAboveThresholdWrongSigReverts() public {
        // Mock accepts a different signature than the one supplied.
        bytes memory goodSig = _makeSig(0x42);
        bytes memory badSig = _makeSig(0x99);
        bytes memory msgBytes = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 1, true, goodSig, msgBytes);
        vm.prank(owner);
        vm.expectRevert("invalid PQ signature");
        vault.queueWithdrawal(recipient, 2 ether, badSig);
    }

    function testQueueAboveThresholdUnregisteredKeyReverts() public {
        bytes memory sig = _makeSig(0x42);
        bytes memory msgBytes = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(false, 1, true, sig, msgBytes);
        vm.prank(owner);
        vm.expectRevert("owner has no PQC key");
        vault.queueWithdrawal(recipient, 2 ether, sig);
    }

    function testQueueAboveThresholdWrongAlgoReverts() public {
        bytes memory sig = _makeSig(0x42);
        bytes memory msgBytes = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 2, true, sig, msgBytes);
        vm.prank(owner);
        vm.expectRevert("owner key is not ML-DSA-87");
        vault.queueWithdrawal(recipient, 2 ether, sig);
    }

    function testQueueAboveThresholdPossessionNotProvenReverts() public {
        // A copied key (registered without proof of possession) must NOT pass.
        bytes memory sig = _makeSig(0x42);
        bytes memory msgBytes = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 1, false, sig, msgBytes);
        vm.prank(owner);
        vm.expectRevert("owner key possession not proven");
        vault.queueWithdrawal(recipient, 2 ether, sig);
    }

    function testQueueAboveThresholdWithoutPrecompilesReverts() public {
        // Fail closed: with no code at the precompile addresses (inactive
        // precompiles), the high-level call reverts and the queue fails.
        bytes memory sig = _makeSig(0x42);
        vm.prank(owner);
        vm.expectRevert();
        vault.queueWithdrawal(recipient, 2 ether, sig);
    }

    function testPqSignatureBindsAmount() public {
        // A signature made for 2 ether must not authorise a 3 ether queue:
        // the vault hashes the actual amount, the mock rejects the mismatch.
        bytes memory sig = _makeSig(0x42);
        bytes memory msgFor2 = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 1, true, sig, msgFor2);
        vm.prank(owner);
        vm.expectRevert("invalid PQ signature");
        vault.queueWithdrawal(recipient, 3 ether, sig);
    }

    function testPqSignatureBindsRecipient() public {
        bytes memory sig = _makeSig(0x42);
        bytes memory msgForRecipient = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 1, true, sig, msgForRecipient);
        vm.prank(owner);
        vm.expectRevert("invalid PQ signature");
        vault.queueWithdrawal(attacker, 2 ether, sig);
    }

    function testPqNoncePreventsReplay() public {
        // First above-threshold queue consumes nonce 0; replaying the same
        // signature bytes for an identical second queue must fail because
        // the vault now signs with nonce 1.
        bytes memory sig = _makeSig(0x42);
        bytes memory msg0 = _vaultMessage(0, recipient, 2 ether, 0);
        _etchMock(true, 1, true, sig, msg0);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 2 ether, sig);
        assertEq(vault.pqNonce(), 1);
        // Same signature, same params, new id + new nonce -> different hash.
        vm.prank(owner);
        vm.expectRevert("invalid PQ signature");
        vault.queueWithdrawal(recipient, 2 ether, sig);
    }

    // ------------------------------------------------------------------------
    // Execute
    // ------------------------------------------------------------------------

    function testExecuteBeforeTimelockReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.prank(owner);
        vm.expectRevert("timelock not passed");
        vault.executeWithdrawal(0);
    }

    function testExecuteAfterTimelockSucceeds() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalExecuted(0, recipient, 0.5 ether);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(recipient.balance, 0.5 ether);
        assertEq(vault.balance(), 19.5 ether);
        (,,,, PQTimelockVault.Status status) = vault.getWithdrawal(0);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Executed));
    }

    function testExecuteTwiceReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        vm.prank(owner);
        vm.expectRevert("not queued");
        vault.executeWithdrawal(0);
    }

    function testExecuteUnknownIdReverts() public {
        vm.prank(owner);
        vm.expectRevert("unknown withdrawal");
        vault.executeWithdrawal(7);
    }

    function testExecuteByNonOwnerReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(attacker);
        vm.expectRevert("not owner");
        vault.executeWithdrawal(0);
    }

    /// @dev Two queues can each pass the queue-time balance check while their
    ///      sum exceeds the balance; the second execute must fail with a
    ///      clear reason instead of a bare transfer revert, and the entry
    ///      must stay Queued (executable again after a top-up).
    function testExecuteInsufficientVaultBalanceReverts() public {
        // High threshold (no PQ path) and high daily limit (not in play).
        _redeployVault(100 ether, 100 ether);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 15 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 10 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(vault.balance(), 5 ether);
        vm.prank(owner);
        vm.expectRevert("insufficient vault balance");
        vault.executeWithdrawal(1);
        (,,,, PQTimelockVault.Status status) = vault.getWithdrawal(1);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Queued));
        // After a top-up the same entry executes fine.
        vm.prank(owner);
        vault.deposit{value: 10 ether}();
        vm.prank(owner);
        vault.executeWithdrawal(1);
        assertEq(recipient.balance, 25 ether);
    }

    // ------------------------------------------------------------------------
    // Cancel / guardian
    // ------------------------------------------------------------------------

    function testGuardianCancelSucceeds() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.expectEmit(true, true, false, false, address(vault));
        emit WithdrawalCancelled(0, guardian);
        vm.prank(guardian);
        vault.cancelWithdrawal(0);
        (,,,, PQTimelockVault.Status status) = vault.getWithdrawal(0);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Cancelled));
        // Funds stay in the vault.
        assertEq(vault.balance(), 20 ether);
        assertEq(recipient.balance, 0);
    }

    function testOwnerCancelSucceeds() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.prank(owner);
        vault.cancelWithdrawal(0);
        (,,,, PQTimelockVault.Status status) = vault.getWithdrawal(0);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Cancelled));
    }

    function testCancelByStrangerReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.prank(attacker);
        vm.expectRevert("not guardian or owner");
        vault.cancelWithdrawal(0);
    }

    function testCancelAfterExecuteReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        vm.prank(guardian);
        vm.expectRevert("not queued");
        vault.cancelWithdrawal(0);
    }

    function testCancelAfterCancelReverts() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.prank(guardian);
        vault.cancelWithdrawal(0);
        vm.prank(guardian);
        vm.expectRevert("not queued");
        vault.cancelWithdrawal(0);
    }

    function testGuardianCannotExecute() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(guardian);
        vm.expectRevert("not owner");
        vault.executeWithdrawal(0);
    }

    function testGuardianCannotQueue() public {
        vm.prank(guardian);
        vm.expectRevert("not owner");
        vault.queueWithdrawal(recipient, 0.5 ether, "");
    }

    function testGuardianCannotSetGuardian() public {
        vm.prank(guardian);
        vm.expectRevert("not owner");
        vault.setGuardian(attacker);
    }

    function testNoGuardianVaultOwnerCanStillCancel() public {
        PQTimelockVault noGuardian =
            new PQTimelockVault(owner, address(0), TIMELOCK, PQ_THRESHOLD, DAILY_LIMIT);
        vm.prank(owner);
        noGuardian.deposit{value: 5 ether}();
        vm.prank(owner);
        noGuardian.queueWithdrawal(recipient, 1 ether, "");
        vm.prank(attacker);
        vm.expectRevert("not guardian or owner");
        noGuardian.cancelWithdrawal(0);
        vm.prank(owner);
        noGuardian.cancelWithdrawal(0);
    }

    // ------------------------------------------------------------------------
    // setGuardian
    // ------------------------------------------------------------------------

    function testSetGuardianByOwner() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit GuardianChanged(guardian, attacker);
        vm.prank(owner);
        vault.setGuardian(attacker);
        assertEq(vault.guardian(), attacker);
    }

    function testSetGuardianByNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert("not owner");
        vault.setGuardian(attacker);
    }

    function testOldGuardianLosesCancelPower() public {
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 0.5 ether, "");
        vm.prank(owner);
        vault.setGuardian(attacker);
        vm.prank(guardian);
        vm.expectRevert("not guardian or owner");
        vault.cancelWithdrawal(0);
        vm.prank(attacker);
        vault.cancelWithdrawal(0);
    }

    // ------------------------------------------------------------------------
    // Daily limit (rolling 24h)
    // ------------------------------------------------------------------------

    function testDailyLimitBlocksSecondExecution() public {
        _redeployVault(10 ether, DAILY_LIMIT);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 3 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 3 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(vault.withdrawnLast24h(), 3 ether);
        vm.prank(owner);
        vm.expectRevert("daily limit exceeded");
        vault.executeWithdrawal(1);
    }

    function testDailyLimitRollsOverAfter24h() public {
        _redeployVault(10 ether, DAILY_LIMIT);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 3 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 3 ether, "");
        // t0 is read BEFORE any warp in this test; it is the pre-warp
        // baseline all later warps are computed from, by design.
        // forge-lint: disable-next-line(environment-read-across-mutation)
        uint256 t0 = block.timestamp;
        vm.warp(t0 + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        vm.prank(owner);
        vm.expectRevert("daily limit exceeded");
        vault.executeWithdrawal(1);
        // 24h after the first execution, its amount leaves the window.
        vm.warp(t0 + TIMELOCK + 24 hours + 1);
        assertEq(vault.withdrawnLast24h(), 0);
        vm.prank(owner);
        vault.executeWithdrawal(1);
        assertEq(recipient.balance, 6 ether);
    }

    function testDailyLimitPartialWindow() public {
        _redeployVault(10 ether, DAILY_LIMIT);
        // Two executions 12h apart: after 24h from the first, only the
        // second still counts.
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 2 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 2 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 2 ether, "");
        // t0 is read BEFORE any warp in this test; it is the pre-warp
        // baseline all later warps are computed from, by design.
        // forge-lint: disable-next-line(environment-read-across-mutation)
        uint256 t0 = block.timestamp;
        vm.warp(t0 + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0); // t
        vm.warp(t0 + TIMELOCK + 12 hours);
        vm.prank(owner);
        vault.executeWithdrawal(1); // t + 12h
        assertEq(vault.withdrawnLast24h(), 4 ether);
        // Third (2 ether) would total 6 > 5: blocked.
        vm.prank(owner);
        vm.expectRevert("daily limit exceeded");
        vault.executeWithdrawal(2);
        // 24h after the FIRST execution: only the second (2 ether) counts,
        // so 2 + 2 = 4 <= 5 passes.
        vm.warp(t0 + TIMELOCK + 24 hours + 1);
        assertEq(vault.withdrawnLast24h(), 2 ether);
        vm.prank(owner);
        vault.executeWithdrawal(2);
    }

    function testDailyLimitExactBoundaryPasses() public {
        _redeployVault(10 ether, DAILY_LIMIT);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, 5 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(vault.withdrawnLast24h(), 5 ether);
    }

    // ------------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------------

    function testReentrancyCannotDrainVault() public {
        // Queue two withdrawals to the attacker contract; the second is the
        // reentrancy target.
        ReentrantAttacker evil = new ReentrantAttacker(vault, 0, 1);
        vm.prank(owner);
        vault.queueWithdrawal(address(evil), 1 ether, "");
        vm.prank(owner);
        vault.queueWithdrawal(address(evil), 1 ether, "");
        vm.warp(block.timestamp + TIMELOCK);
        uint256 vaultBefore = vault.balance();
        vm.prank(owner);
        vault.executeWithdrawal(0);
        // The attacker DID try to re-enter (receive ran).
        assertGt(evil.reenterAttempts(), 0);
        // But exactly one withdrawal left the vault.
        assertEq(vault.balance(), vaultBefore - 1 ether);
        assertEq(address(evil).balance, 1 ether);
        // The second withdrawal is still queued, untouched.
        (,,,, PQTimelockVault.Status status) = vault.getWithdrawal(1);
        assertEq(uint256(status), uint256(PQTimelockVault.Status.Queued));
    }

    // ------------------------------------------------------------------------
    // Fuzz: deposit / queue / execute accounting (below threshold)
    // ------------------------------------------------------------------------

    function testFuzz_DepositQueueExecute(uint96 fuzzAmount) public {
        uint256 amount = bound(fuzzAmount, 1 wei, 1 ether);
        vm.prank(owner);
        vault.queueWithdrawal(recipient, amount, "");
        vm.warp(block.timestamp + TIMELOCK);
        uint256 recipientBefore = recipient.balance;
        vm.prank(owner);
        vault.executeWithdrawal(0);
        assertEq(recipient.balance, recipientBefore + amount);
        assertEq(vault.balance(), 20 ether - amount);
    }
}
