// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PQTimelockVault
/// @notice A post-quantum timelock vault for QoreChain (Build Before Q-Day).
/// @dev Combines four controls in one vault:
///      1. Timelock — a queued withdrawal can only execute after
///         `queuedAt + timelockSeconds`.
///      2. Guardian — a guardian (or the owner) can cancel a queued withdrawal.
///         The guardian can NEVER move funds, change the owner, or change the
///         guardian.
///      3. Daily limit — executions in any rolling 24h window may not exceed
///         `dailyLimit`.
///      4. Post-quantum threshold — withdrawals above `pqThreshold` require a
///         valid ML-DSA-87 signature by the owner, verified on-chain through
///         QoreChain's PQC precompiles (0x0A01 pqcVerify, 0x0A02 pqcKeyStatus).
///
///      PQ message scheme (documented in README.md):
///        message = keccak256(abi.encode(
///            "PQTimelockVault.withdrawal.v1",
///            block.chainid,
///            address(this),
///            withdrawalId,
///            to,
///            amount,
///            pqNonce
///        ))
///      The owner signs exactly these 32 bytes with their ML-DSA-87 secret key.
///      The signature binds the chain, the vault, the queue id, the recipient,
///      the amount and a one-time nonce, so it cannot replay anywhere else.
///      `pqNonce` increments on every above-threshold queue.
///
///      Precompile interface (verified 2026-11-16 from public sources:
///      docs.qorechain.io EVM Guide, the qorechain evm npm package 0.12.0
///      (IQORE_PQC_ABI), and github.com/qorechain/qorechain-core
///      docs/EVM_PRECOMPILES.md + x/vm/precompiles/addresses.go):
///        pqcVerify(bytes pubkey, bytes signature, bytes message)
///            view returns (bool valid)              — 0x0A01
///        pqcKeyStatus(address account) view returns
///            (bool registered, uint8 algorithmId, bytes pubkey,
///             bool possessionProven)                — 0x0A02
///      The chain's own docs require checking `possessionProven`: anyone can
///      register someone else's public key for their own account, so a contract
///      that verifies "a signature by X" against X's registered key MUST
///      require the possession proof, or a copied key lets one address pass
///      as another. This contract requires it.
interface IQorePQC {
    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        view
        returns (bool valid);

    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool possessionProven);
}

contract PQTimelockVault {
    // ------------------------------------------------------------------------
    // Precompiles (QoreChain; active on testnet qorechain-diana, chain id 9800)
    // ------------------------------------------------------------------------

    /// @dev ML-DSA-87 signature verification precompile.
    IQorePQC internal constant PQC_VERIFY = IQorePQC(0x0000000000000000000000000000000000000a01);
    /// @dev Registered PQC key lookup precompile.
    IQorePQC internal constant PQC_KEY_STATUS = IQorePQC(0x0000000000000000000000000000000000000a02);

    /// @dev ML-DSA-87 (FIPS 204, Dilithium-5) sizes, per the chain docs.
    uint256 public constant ML_DSA_87_PUBLIC_KEY_LENGTH = 2592;
    uint256 public constant ML_DSA_87_SIGNATURE_LENGTH = 4627;
    /// @dev algorithmId reported by pqcKeyStatus for ML-DSA-87.
    uint8 public constant ML_DSA_87_ALGORITHM_ID = 1;

    /// @dev Rolling window for the daily limit: 24 hours.
    uint256 public constant WINDOW = 24 hours;

    // ------------------------------------------------------------------------
    // Roles & parameters
    // ------------------------------------------------------------------------

    address public owner;
    address public guardian;
    uint256 public timelockSeconds;
    uint256 public pqThreshold;
    uint256 public dailyLimit;

    /// @dev One-time nonce for above-threshold PQ signatures. Incremented on
    ///      every above-threshold queue; part of the signed message.
    uint256 public pqNonce;

    // ------------------------------------------------------------------------
    // Withdrawal queue
    // ------------------------------------------------------------------------

    enum Status {
        Queued,
        Executed,
        Cancelled
    }

    struct Withdrawal {
        address to;
        uint256 amount;
        uint256 queuedAt;
        Status status;
    }

    Withdrawal[] internal withdrawals;

    // ------------------------------------------------------------------------
    // Rolling 24h execution window
    // ------------------------------------------------------------------------

    struct Execution {
        uint256 amount;
        uint256 executedAt;
    }

    Execution[] internal executions;
    /// @dev Index of the first execution that may still be inside the window.
    ///      Entries before it are older than 24h and were pruned. Keeps the
    ///      window sum loop bounded by executions in the last 24h.
    uint256 internal windowHead;

    // ------------------------------------------------------------------------
    // Reentrancy guard (no external dependency; single-purpose vault)
    // ------------------------------------------------------------------------

    uint256 internal locked;

    modifier nonReentrant() {
        require(locked == 0, "reentrant");
        locked = 1;
        _;
        locked = 0;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount);
    event WithdrawalQueued(uint256 indexed id, address indexed to, uint256 amount, uint256 executeAfter);
    event WithdrawalExecuted(uint256 indexed id, address indexed to, uint256 amount);
    event WithdrawalCancelled(uint256 indexed id, address indexed by);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(
        address _owner,
        // address(0) is a valid "no guardian" value; the owner can still cancel.
        // forge-lint: disable-next-line(missing-zero-check)
        address _guardian,
        uint256 _timelockSeconds,
        uint256 _pqThreshold,
        uint256 _dailyLimit
    ) {
        require(_owner != address(0), "owner is zero");
        owner = _owner;
        // _guardian may be address(0) = no guardian; owner can still cancel.
        guardian = _guardian;
        timelockSeconds = _timelockSeconds;
        pqThreshold = _pqThreshold;
        dailyLimit = _dailyLimit;
    }

    // ------------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------------

    /// @notice Deposit native QOR. Anyone may deposit.
    function deposit() public payable {
        require(msg.value > 0, "zero deposit");
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Plain transfers are accepted as deposits.
    receive() external payable {
        require(msg.value > 0, "zero deposit");
        emit Deposited(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------------
    // PQ message scheme
    // ------------------------------------------------------------------------

    /// @notice The exact 32-byte message the owner must sign (ML-DSA-87) for
    ///         an above-threshold withdrawal. Read this off-chain, sign it
    ///         with the owner's PQC secret key, pass the signature to
    ///         `queueWithdrawal`. `id` is the next queue id (`queuedCount()`)
    ///         and `nonce` is the current `pqNonce()` at signing time.
    function pqMessageHash(uint256 id, address to, uint256 amount, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                "PQTimelockVault.withdrawal.v1",
                block.chainid,
                address(this),
                id,
                to,
                amount,
                nonce
            )
        );
    }

    /// @dev Verify an above-threshold withdrawal signature against the owner's
    ///      registered key. Reverts unless the key is registered, is
    ///      ML-DSA-87, has a proven possession, and the signature is valid.
    ///      Fails closed: on a network where the precompiles are inactive the
    ///      high-level call reverts (no code at the precompile address), so an
    ///      above-threshold queue cannot succeed without real verification.
    function _verifyOwnerPQSignature(bytes calldata pqSignature, bytes32 messageHash) internal view {
        require(pqSignature.length == ML_DSA_87_SIGNATURE_LENGTH, "bad PQ signature length");
        (bool registered, uint8 algorithmId, bytes memory pubkey, bool possessionProven) =
            PQC_KEY_STATUS.pqcKeyStatus(owner);
        require(registered, "owner has no PQC key");
        require(algorithmId == ML_DSA_87_ALGORITHM_ID, "owner key is not ML-DSA-87");
        require(possessionProven, "owner key possession not proven");
        require(pubkey.length == ML_DSA_87_PUBLIC_KEY_LENGTH, "bad owner PQC key length");
        bool valid = PQC_VERIFY.pqcVerify(pubkey, pqSignature, abi.encodePacked(messageHash));
        require(valid, "invalid PQ signature");
    }

    // ------------------------------------------------------------------------
    // Queue / execute / cancel
    // ------------------------------------------------------------------------

    /// @notice Queue a withdrawal. Only the owner. Above `pqThreshold` the
    ///         call must carry a valid ML-DSA-87 signature by the owner over
    ///         `pqMessageHash(id, to, amount, pqNonce)`; below the threshold
    ///         the signature is ignored (may be empty).
    /// @return id The queue id of the new withdrawal.
    function queueWithdrawal(address to, uint256 amount, bytes calldata pqSignature)
        external
        onlyOwner
        returns (uint256 id)
    {
        require(to != address(0), "recipient is zero");
        require(amount > 0, "zero amount");
        require(amount <= address(this).balance, "exceeds vault balance");

        id = withdrawals.length;
        if (amount > pqThreshold) {
            bytes32 messageHash = pqMessageHash(id, to, amount, pqNonce);
            _verifyOwnerPQSignature(pqSignature, messageHash);
            unchecked {
                ++pqNonce;
            }
        }

        withdrawals.push(
            Withdrawal({to: to, amount: amount, queuedAt: block.timestamp, status: Status.Queued})
        );
        emit WithdrawalQueued(id, to, amount, block.timestamp + timelockSeconds);
    }

    /// @notice Execute a queued withdrawal after the timelock, within the
    ///         rolling 24h daily limit. Only the owner. This is the ONLY
    ///         function that moves funds out of the vault.
    function executeWithdrawal(uint256 id) external nonReentrant onlyOwner {
        require(id < withdrawals.length, "unknown withdrawal");
        Withdrawal storage w = withdrawals[id];
        require(w.status == Status.Queued, "not queued");
        // A timelock IS a timestamp comparison by design; a few seconds of
        // block-time skew are immaterial next to a 60s–24h timelock.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= w.queuedAt + timelockSeconds, "timelock not passed");
        require(_withdrawnLast24h() + w.amount <= dailyLimit, "daily limit exceeded");
        require(w.amount <= address(this).balance, "insufficient vault balance");

        // Effects before interaction.
        w.status = Status.Executed;
        _recordExecution(w.amount);

        // The nonReentrant guard is set before this call and all state effects
        // are already applied; a reentrant call reverts at the guard.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = w.to.call{value: w.amount}("");
        require(ok, "transfer failed");
        // Same reason: the guard blocks reentrancy, so the event cannot be
        // reordered by a reentrant call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalExecuted(id, w.to, w.amount);
    }

    /// @notice Cancel a queued withdrawal. Guardian or owner only. Funds stay
    ///         in the vault. The guardian cannot move funds in any way.
    function cancelWithdrawal(uint256 id) external {
        require(msg.sender == owner || (guardian != address(0) && msg.sender == guardian), "not guardian or owner");
        require(id < withdrawals.length, "unknown withdrawal");
        Withdrawal storage w = withdrawals[id];
        require(w.status == Status.Queued, "not queued");
        w.status = Status.Cancelled;
        emit WithdrawalCancelled(id, msg.sender);
    }

    /// @notice Replace the guardian. Only the owner. `address(0)` removes it.
    // address(0) is the documented way to remove the guardian.
    // forge-lint: disable-next-line(missing-zero-check)
    function setGuardian(address newGuardian) external onlyOwner {
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianChanged(oldGuardian, newGuardian);
    }

    // ------------------------------------------------------------------------
    // Rolling 24h window accounting
    // ------------------------------------------------------------------------

    /// @dev Sum of executions in the last 24h, pruning expired entries from
    ///      the head first (state-changing; used by execute).
    function _withdrawnLast24h() internal returns (uint256 sum) {
        uint256 len = executions.length;
        // The rolling window is defined by wall-clock time; block-time skew
        // of a few seconds cannot move a 24h boundary meaningfully.
        // forge-lint: disable-next-line(block-timestamp)
        while (windowHead < len && executions[windowHead].executedAt + WINDOW <= block.timestamp) {
            unchecked {
                ++windowHead;
            }
        }
        for (uint256 i = windowHead; i < len; ++i) {
            sum += executions[i].amount;
        }
    }

    function _recordExecution(uint256 amount) internal {
        executions.push(Execution({amount: amount, executedAt: block.timestamp}));
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice Withdrawal entry by id.
    function getWithdrawal(uint256 id)
        external
        view
        returns (address to, uint256 amount, uint256 queuedAt, uint256 executeAfter, Status status)
    {
        require(id < withdrawals.length, "unknown withdrawal");
        Withdrawal storage w = withdrawals[id];
        return (w.to, w.amount, w.queuedAt, w.queuedAt + timelockSeconds, w.status);
    }

    /// @notice Number of withdrawals ever queued (also the next queue id).
    function queuedCount() external view returns (uint256) {
        return withdrawals.length;
    }

    /// @notice Total executed in the last 24 hours (rolling window).
    function withdrawnLast24h() external view returns (uint256 sum) {
        uint256 len = executions.length;
        for (uint256 i = windowHead; i < len; ++i) {
            // Same rolling-window justification as _withdrawnLast24h.
            // forge-lint: disable-next-line(block-timestamp)
            if (executions[i].executedAt + WINDOW > block.timestamp) {
                sum += executions[i].amount;
            }
        }
    }

    /// @notice Vault native balance.
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Number of execution records kept (grows by one per execution;
    ///         old entries are skipped via the window head, never deleted).
    function executionCount() external view returns (uint256) {
        return executions.length;
    }
}
