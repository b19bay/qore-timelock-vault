// Vault configuration + QoreChain PQC precompile bindings for the dApp.
//
// The vault address comes from VITE_VAULT_ADDRESS (see .env.example).
// Devnet deployment (local devnet only, not reachable from the public
// internet): 0x32b60D0fA270a2148dBD3386123b1979b15D0814
// Testnet deployment is a separate step — see README § Deploy.

export const VAULT_ADDRESS = (
  import.meta.env.VITE_VAULT_ADDRESS as string | undefined
)?.toLowerCase() as `0x${string}` | undefined;

export const DEVNET_VAULT_ADDRESS =
  "0xb6c45e628188DD084879Bc0eEC2813d6c8Fd755D" as const;

/** QoreChain PQC precompiles (active on testnet qorechain-diana, 9800). */
export const PQC_VERIFY_ADDRESS =
  "0x0000000000000000000000000000000000000a01" as const;
export const PQC_KEY_STATUS_ADDRESS =
  "0x0000000000000000000000000000000000000a02" as const;

/** Minimal ABI for reading an account's registered PQC key (IQorePQC). */
export const PQC_KEY_STATUS_ABI = [
  {
    type: "function",
    name: "pqcKeyStatus",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "registered", type: "bool" },
      { name: "algorithmId", type: "uint8" },
      { name: "pubkey", type: "bytes" },
      { name: "possessionProven", type: "bool" },
    ],
  },
] as const;

/** ML-DSA-87 sizes (chain docs). */
export const ML_DSA_87_SIGNATURE_BYTES = 4627;
export const ML_DSA_87_PUBLIC_KEY_BYTES = 2592;

export function formatCountdown(secondsLeft: number): string {
  if (secondsLeft <= 0) return "ready";
  const h = Math.floor(secondsLeft / 3600);
  const m = Math.floor((secondsLeft % 3600) / 60);
  const s = secondsLeft % 60;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}
