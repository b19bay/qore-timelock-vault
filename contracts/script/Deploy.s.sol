// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PQTimelockVault} from "../src/PQTimelockVault.sol";

/// @notice Deploy PQTimelockVault to a QoreChain network (devnet or testnet).
///
/// @dev Parameters come from environment variables (no secrets in this file;
///      the deployer key is passed with --private-key at runtime and is never
///      written anywhere):
///        VAULT_OWNER       owner address (required)
///        VAULT_GUARDIAN    guardian address (optional, default address(0))
///        VAULT_TIMELOCK    timelock seconds (optional, default 86400 = 24h)
///        VAULT_PQ_THRESHOLD pq threshold in wei (optional, default 1 ether)
///        VAULT_DAILY_LIMIT daily limit in wei (optional, default 5 ether)
///
///      Before deploying, the deployer account needs a registered ML-DSA-87
///      key and an open EVM authorisation window (native lane), and the
///      account must be a UNIFIED eth-native account (eth_secp256k1) — a
///      plain Cosmos secp256k1 key cannot send EVM transactions (its EVM
///      sender differs from its bech32 address). See README § Deploy.
///
///      Devnet example (from contracts/):
///        VAULT_OWNER=0x1A79... VAULT_GUARDIAN=0xd40C... VAULT_TIMELOCK=60 \
///          forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
///          --private-key $KEY --gas-limit 3000000 --broadcast
contract Deploy is Script {
    function run() public returns (PQTimelockVault vault) {
        address owner = vm.envAddress("VAULT_OWNER");
        address guardian = vm.envOr("VAULT_GUARDIAN", address(0));
        uint256 timelock = vm.envOr("VAULT_TIMELOCK", uint256(86400));
        uint256 pqThreshold = vm.envOr("VAULT_PQ_THRESHOLD", uint256(1 ether));
        uint256 dailyLimit = vm.envOr("VAULT_DAILY_LIMIT", uint256(5 ether));

        vm.startBroadcast();
        vault = new PQTimelockVault(owner, guardian, timelock, pqThreshold, dailyLimit);
        vm.stopBroadcast();

        console.log("PQTimelockVault deployed at:", address(vault));
        console.log("owner:", vault.owner());
        console.log("guardian:", vault.guardian());
        console.log("timelockSeconds:", vault.timelockSeconds());
        console.log("pqThreshold:", vault.pqThreshold());
        console.log("dailyLimit:", vault.dailyLimit());
    }
}
