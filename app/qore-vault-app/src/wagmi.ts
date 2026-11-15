import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { qorechain, qorechainTestnet } from "@qorechain/evm";
import { qorexWallet } from "@qorechain/qorex-rainbowkit";
import { createConfig, http } from "wagmi";

// QoreX first, then any other injected (EIP-1193) wallet. Neither uses
// WalletConnect, so the project id is only a placeholder unless you add a
// WalletConnect-based wallet.
const connectors = connectorsForWallets(
  [
    {
      groupName: "Recommended",
      wallets: [() => qorexWallet({ pollAccountsOnFocus: true }), injectedWallet],
    },
  ],
  {
    appName: "QoreChain dApp",
    projectId: import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ?? "unused",
  },
);

// The testnet is listed first, so a fresh connection lands there.
//
// VITE_EVM_RPC_URL (optional) overrides the testnet chain's RPC endpoint —
// set it to http://localhost:8545 to run this app against the local devnet
// (the devnet's EVM chain id is also 9800). Without it, the chain's default
// public testnet RPC is used.
const testnetTransport =
  import.meta.env.VITE_EVM_RPC_URL !== undefined && import.meta.env.VITE_EVM_RPC_URL !== ""
    ? http(import.meta.env.VITE_EVM_RPC_URL as string)
    : http();

export const config = createConfig({
  chains: [qorechainTestnet, qorechain],
  connectors,
  transports: {
    [qorechainTestnet.id]: testnetTransport,
    [qorechain.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
