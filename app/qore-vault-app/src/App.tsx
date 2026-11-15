import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  QORECHAIN_REST_ENDPOINTS,
  classifyEvmWindowRejection,
  evmWindowStatus,
  qorechainTestnet,
  type EvmWindowRejection,
} from "@qorechain/evm";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { formatEther, isAddress, parseEther } from "viem";
import {
  useAccount,
  useBalance,
  useBlockNumber,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { VAULT_ABI } from "./vaultAbi.js";
import {
  DEVNET_VAULT_ADDRESS,
  ML_DSA_87_SIGNATURE_BYTES,
  PQC_KEY_STATUS_ABI,
  PQC_KEY_STATUS_ADDRESS,
  VAULT_ADDRESS,
  formatCountdown,
} from "./vault.js";

const REMEDY: Record<EvmWindowRejection, string> = {
  "no-pqc-key":
    "This account has no registered ML-DSA-87 key. Register one on the native lane first.",
  "no-window": "No EVM authorisation window is open. Open one on the native lane, then retry.",
  exhausted: "The window has run out of blocks, transactions or value. Open a new one.",
  invalid: "The chain refused the window parameters.",
};

/** The REST API of each chain, through the dev server's proxy (vite.config.ts). */
const REST_PROXY: Record<number, string | undefined> = Object.fromEntries(
  Object.keys(QORECHAIN_REST_ENDPOINTS).map((id) => [
    Number(id),
    Number(id) === qorechainTestnet.id ? "/lcd-testnet" : "/lcd-mainnet",
  ]),
);

/** The account's EVM authorisation window, read over the native-lane REST API. */
function WindowStatus({ address, chainId }: { address: `0x${string}`; chainId: number }) {
  const rest = REST_PROXY[chainId];
  const { data, error, isLoading } = useQuery({
    queryKey: ["evm-window", chainId, address],
    queryFn: () => evmWindowStatus({ rest: rest!, address }),
    enabled: rest !== undefined,
    refetchInterval: 10_000,
  });
  if (!rest) return <p>Unknown network.</p>;
  if (isLoading) return <p>Reading the EVM window…</p>;
  if (error) {
    return (
      <p>
        Could not read the EVM window over REST ({error.message}). On the local devnet the REST
        endpoint is off — check the window with{" "}
        <code>qorechaind query pqc evm-window &lt;address&gt;</code> instead.
      </p>
    );
  }
  if (!data?.found) {
    return <p>EVM window: none. Sending from this account is refused until one is opened.</p>;
  }
  return (
    <p>
      EVM window: {data.live ? "live" : "not usable"} ({data.remainingBlocks.toString()} blocks,{" "}
      {data.remainingTxs.toString()} transactions, {data.remainingValue.toString()} uqor left)
    </p>
  );
}

/** Current unix time, ticking once a second, for timelock countdowns. */
function useNowSeconds(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}

function parseQorAmount(input: string): bigint | undefined {
  try {
    const v = parseEther(input.trim() === "" ? "0" : input);
    return v > 0n ? v : undefined;
  } catch {
    return undefined;
  }
}

const STATUS_LABEL = ["Queued", "Executed", "Cancelled"] as const;

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section
      style={{ border: "1px solid #ccc", borderRadius: 8, padding: "1rem", margin: "1rem 0" }}
    >
      <h2 style={{ marginTop: 0 }}>{title}</h2>
      {children}
    </section>
  );
}

export function App() {
  const { address, chainId, isConnected } = useAccount();
  const { data: balance } = useBalance({ address });
  const { data: block } = useBlockNumber({ watch: true });

  if (!VAULT_ADDRESS) {
    return (
      <main style={{ fontFamily: "system-ui, sans-serif", maxWidth: 720, margin: "2rem auto", padding: "0 1rem" }}>
        <h1>PQ Timelock Vault</h1>
        <p>
          No vault configured. Set <code>VITE_VAULT_ADDRESS</code> in{" "}
          <code>app/qore-vault-app/.env</code> (see <code>.env.example</code>). The devnet
          deployment is <code>{DEVNET_VAULT_ADDRESS}</code>; a testnet deployment is a
          separate step — see the README.
        </p>
      </main>
    );
  }
  return (
    <VaultApp
      vault={VAULT_ADDRESS}
      address={address}
      chainId={chainId}
      isConnected={isConnected}
      userBalance={balance?.value}
      block={block}
    />
  );
}

function VaultApp({
  vault,
  address,
  chainId,
  isConnected,
  userBalance,
  block,
}: {
  vault: `0x${string}`;
  address: `0x${string}` | undefined;
  chainId: number | undefined;
  isConnected: boolean;
  userBalance: bigint | undefined;
  block: bigint | undefined;
}) {
  const now = useNowSeconds();
  const { writeContract, data: txHash, error: writeError, isPending } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash: txHash });
  const rejection = writeError ? classifyEvmWindowRejection(writeError) : undefined;

  // ---- Vault reads (refreshed every 5s) ----
  const vaultReads = useReadContracts({
    contracts: [
      { address: vault, abi: VAULT_ABI, functionName: "owner" },
      { address: vault, abi: VAULT_ABI, functionName: "guardian" },
      { address: vault, abi: VAULT_ABI, functionName: "timelockSeconds" },
      { address: vault, abi: VAULT_ABI, functionName: "pqThreshold" },
      { address: vault, abi: VAULT_ABI, functionName: "dailyLimit" },
      { address: vault, abi: VAULT_ABI, functionName: "balance" },
      { address: vault, abi: VAULT_ABI, functionName: "queuedCount" },
      { address: vault, abi: VAULT_ABI, functionName: "withdrawnLast24h" },
      { address: vault, abi: VAULT_ABI, functionName: "pqNonce" },
    ],
    query: { refetchInterval: 5_000 },
  });
  const readResults = (vaultReads.data?.map((r) =>
    r.status === "success" ? r.result : undefined,
  ) ?? []) as [
    `0x${string}` | undefined,
    `0x${string}` | undefined,
    bigint | undefined,
    bigint | undefined,
    bigint | undefined,
    bigint | undefined,
    bigint | undefined,
    bigint | undefined,
    bigint | undefined,
  ];
  const [owner, guardian, timelockSeconds, pqThreshold, dailyLimit, vaultBalance, queuedCount, withdrawn24h, pqNonce] =
    readResults;

  const isOwner = !!address && !!owner && address.toLowerCase() === owner.toLowerCase();
  const isGuardian = !!address && !!guardian && address.toLowerCase() === guardian.toLowerCase();

  // ---- Queue entries ----
  const queueCount = queuedCount === undefined ? 0 : Number(queuedCount);
  const queueReads = useReadContracts({
    contracts: Array.from({ length: queueCount }, (_, i) => ({
      address: vault,
      abi: VAULT_ABI,
      functionName: "getWithdrawal",
      args: [BigInt(i)],
    })),
    query: { refetchInterval: 5_000 },
  });

  // ---- Owner's PQC key status (live precompile read) ----
  const keyStatus = useReadContract({
    address: PQC_KEY_STATUS_ADDRESS,
    abi: PQC_KEY_STATUS_ABI,
    functionName: "pqcKeyStatus",
    args: owner ? [owner] : undefined,
    query: { enabled: owner !== undefined, refetchInterval: 10_000 },
  });
  const [keyRegistered, keyAlgo, keyPubkey, keyProven] =
    keyStatus.data ?? [undefined, undefined, undefined, undefined];

  // Refetch reads after a write confirms.
  useEffect(() => {
    if (receipt.isSuccess) {
      void vaultReads.refetch();
      void queueReads.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt.isSuccess]);

  // ---- Forms ----
  const [depositAmount, setDepositAmount] = useState("");
  const [qTo, setQTo] = useState("");
  const [qAmount, setQAmount] = useState("");
  const [qSig, setQSig] = useState("");
  const [newGuardian, setNewGuardian] = useState("");

  const qAmountWei = parseQorAmount(qAmount);
  const qToValid = isAddress(qTo);
  const needsPq = qAmountWei !== undefined && pqThreshold !== undefined && qAmountWei > pqThreshold;
  const sigHex = qSig.trim().toLowerCase();
  const sigValid =
    sigHex.startsWith("0x") && sigHex.length === 2 + ML_DSA_87_SIGNATURE_BYTES * 2;

  // The exact message the owner must sign for this queue (live from the vault).
  const messageHash = useReadContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "pqMessageHash",
    args:
      needsPq && qToValid && qAmountWei !== undefined && queuedCount !== undefined && pqNonce !== undefined
        ? [queuedCount, qTo as `0x${string}`, qAmountWei, pqNonce]
        : undefined,
    query: { enabled: needsPq && qToValid && qAmountWei !== undefined },
  });

  const depositWei = parseQorAmount(depositAmount);

  return (
    <main style={{ fontFamily: "system-ui, sans-serif", maxWidth: 760, margin: "2rem auto", padding: "0 1rem" }}>
      <h1>PQ Timelock Vault</h1>
      <p>
        A vault with four controls: timelock, guardian cancel, daily limit, and a post-quantum
        (ML-DSA-87) signature threshold. Testnet / devnet only — never mainnet.
      </p>
      <ConnectButton />
      <p>Latest block: {block?.toString() ?? "…"}</p>
      <p>
        Vault: <code>{vault}</code> (chain {chainId ?? "…"})
      </p>

      {isConnected && address && chainId ? (
        <>
          <Section title="EVM authorisation window">
            <WindowStatus address={address} chainId={chainId} />
            <p>
              Every EVM transaction on QoreChain needs an account with a registered ML-DSA-87 key
              and an open authorisation window. The window is opened on the native lane (QoreX or
              the CLI) — this app cannot open it for you. See the{" "}
              <a
                href="https://docs.qorechain.io/sdk/guides/evm/"
                target="_blank"
                rel="noreferrer"
              >
                EVM authorisation window guide
              </a>
              .
            </p>
          </Section>

          <Section title="Vault overview">
            <p>Owner: <code>{owner ?? "…"}</code>{isOwner ? " (you)" : ""}</p>
            <p>Guardian: <code>{guardian ?? "…"}</code>{isGuardian ? " (you)" : ""}</p>
            <p>Timelock: {timelockSeconds !== undefined ? `${timelockSeconds.toString()} seconds` : "…"}</p>
            <p>PQ threshold: {pqThreshold !== undefined ? `${formatEther(pqThreshold)} QOR` : "…"}</p>
            <p>Daily limit: {dailyLimit !== undefined ? `${formatEther(dailyLimit)} QOR / 24h` : "…"}</p>
            <p>Vault balance: {vaultBalance !== undefined ? `${formatEther(vaultBalance)} QOR` : "…"}</p>
            <p>Your balance: {userBalance !== undefined ? `${formatEther(userBalance)} QOR` : "…"}</p>
          </Section>

          <Section title="Daily limit (rolling 24h)">
            {withdrawn24h !== undefined && dailyLimit !== undefined ? (
              <>
                <p>
                  Used: {formatEther(withdrawn24h)} QOR — remaining:{" "}
                  {formatEther(dailyLimit > withdrawn24h ? dailyLimit - withdrawn24h : 0n)} QOR of{" "}
                  {formatEther(dailyLimit)} QOR
                </p>
                <div style={{ background: "#eee", height: 12, borderRadius: 6 }}>
                  <div
                    style={{
                      width: `${dailyLimit === 0n ? 0 : Number((withdrawn24h * 100n) / dailyLimit)}%`,
                      background: "#4a90d9",
                      height: 12,
                      borderRadius: 6,
                    }}
                  />
                </div>
              </>
            ) : (
              <p>…</p>
            )}
          </Section>

          <Section title="Deposit">
            <p>Anyone can deposit native QOR into the vault.</p>
            <input
              value={depositAmount}
              onChange={(e) => setDepositAmount(e.target.value)}
              placeholder="Amount in QOR"
              inputMode="decimal"
              style={{ marginRight: 8 }}
            />
            <button
              type="button"
              disabled={isPending || depositWei === undefined}
              onClick={() =>
                writeContract({ address: vault, abi: VAULT_ABI, functionName: "deposit", value: depositWei! })
              }
            >
              Deposit
            </button>
          </Section>

          <Section title="Queue withdrawal">
            {!isOwner && <p>Only the vault owner can queue withdrawals.</p>}
            <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 480 }}>
              <input
                value={qTo}
                onChange={(e) => setQTo(e.target.value)}
                placeholder="Recipient 0x…"
                style={{ width: "100%" }}
              />
              <input
                value={qAmount}
                onChange={(e) => setQAmount(e.target.value)}
                placeholder="Amount in QOR"
                inputMode="decimal"
              />
              {needsPq && (
                <>
                  <p>
                    This withdrawal is above the PQ threshold (
                    {pqThreshold !== undefined ? formatEther(pqThreshold) : "?"} QOR), so it needs
                    a valid ML-DSA-87 signature by the owner.
                  </p>
                  <p>
                    Owner PQC key:{" "}
                    {keyStatus.isLoading
                      ? "reading…"
                      : keyRegistered === true
                        ? `registered, algorithm ${keyAlgo} (1 = ML-DSA-87), possession proven: ${keyProven ? "yes" : "NO — the vault will refuse this key"}`
                        : "not registered — the vault will refuse the queue"}
                  </p>
                  <p>
                    Message to sign (32 bytes):{" "}
                    <code style={{ wordBreak: "break-all" }}>
                      {messageHash.data ?? "…"}
                    </code>{" "}
                    <button
                      type="button"
                      onClick={() => messageHash.data && navigator.clipboard.writeText(messageHash.data)}
                    >
                      Copy
                    </button>
                  </p>
                  <p>
                    Your browser wallet cannot sign ML-DSA-87. Sign the message hash above with
                    the QoreChain SDK or CLI using your own PQC key (see the README section
                    “Signing a withdrawal”), then paste the <em>signature</em> (4,627 bytes hex)
                    here. Never paste a private key, seed phrase, or mnemonic anywhere — this
                    page never asks for one.
                  </p>
                  <textarea
                    value={qSig}
                    onChange={(e) => setQSig(e.target.value)}
                    placeholder="0x… (ML-DSA-87 signature, 4,627 bytes)"
                    rows={3}
                    style={{ width: "100%" }}
                  />
                  {qSig.trim() !== "" && !sigValid && (
                    <p>Signature must be exactly {ML_DSA_87_SIGNATURE_BYTES} bytes (hex with 0x prefix).</p>
                  )}
                </>
              )}
              <div>
                <button
                  type="button"
                  disabled={
                    isPending ||
                    !isOwner ||
                    !qToValid ||
                    qAmountWei === undefined ||
                    (needsPq && !sigValid)
                  }
                  onClick={() =>
                    writeContract({
                      address: vault,
                      abi: VAULT_ABI,
                      functionName: "queueWithdrawal",
                      args: [qTo as `0x${string}`, qAmountWei!, needsPq ? (sigHex as `0x${string}`) : "0x"],
                    })
                  }
                >
                  Queue withdrawal
                </button>
              </div>
            </div>
          </Section>

          <Section title={`Withdrawal queue (${queueCount})`}>
            {queueCount === 0 && <p>No withdrawals queued.</p>}
            {queueReads.data?.map((r, i) => {
              if (r.status !== "success") return <p key={i}>Entry {i}: loading…</p>;
              const [to, amount, queuedAt, executeAfter, status] = r.result as unknown as [
                `0x${string}`,
                bigint,
                bigint,
                bigint,
                number,
              ];
              const secondsLeft = Number(executeAfter) - now;
              const executable = status === 0 && secondsLeft <= 0;
              return (
                <div key={i} style={{ borderTop: "1px solid #ddd", padding: "0.5rem 0" }}>
                  <p>
                    #{i} → <code>{to}</code> — {formatEther(amount)} QOR —{" "}
                    {STATUS_LABEL[status] ?? status}
                  </p>
                  <p>
                    {status === 0 &&
                      (secondsLeft > 0
                        ? `Executable in ${formatCountdown(secondsLeft)}`
                        : "Timelock passed — ready to execute")}
                    {status !== 0 && `Queued at ${new Date(Number(queuedAt) * 1000).toLocaleString()}`}
                  </p>
                  {status === 0 && (
                    <div style={{ display: "flex", gap: 8 }}>
                      <button
                        type="button"
                        disabled={isPending || !isOwner || !executable}
                        title={!isOwner ? "Only the owner can execute" : !executable ? "Timelock has not passed" : ""}
                        onClick={() =>
                          writeContract({
                            address: vault,
                            abi: VAULT_ABI,
                            functionName: "executeWithdrawal",
                            args: [BigInt(i)],
                          })
                        }
                      >
                        Execute
                      </button>
                      <button
                        type="button"
                        disabled={isPending || (!isOwner && !isGuardian)}
                        title={!isOwner && !isGuardian ? "Only the guardian or owner can cancel" : ""}
                        onClick={() =>
                          writeContract({
                            address: vault,
                            abi: VAULT_ABI,
                            functionName: "cancelWithdrawal",
                            args: [BigInt(i)],
                          })
                        }
                      >
                        Cancel
                      </button>
                    </div>
                  )}
                </div>
              );
            })}
          </Section>

          <Section title="Guardian">
            <p>
              Current guardian: <code>{guardian ?? "…"}</code>
              {guardian === "0x0000000000000000000000000000000000000000" ? " (none)" : ""}
            </p>
            <p>The guardian can only cancel queued withdrawals — never move funds.</p>
            <input
              value={newGuardian}
              onChange={(e) => setNewGuardian(e.target.value)}
              placeholder="New guardian 0x… (0x000…0 removes it)"
              style={{ marginRight: 8, width: 420 }}
            />
            <button
              type="button"
              disabled={isPending || !isOwner || !isAddress(newGuardian)}
              onClick={() =>
                writeContract({
                  address: vault,
                  abi: VAULT_ABI,
                  functionName: "setGuardian",
                  args: [newGuardian as `0x${string}`],
                })
              }
            >
              Set guardian
            </button>
            {!isOwner && <p>Only the owner can change the guardian.</p>}
          </Section>

          {txHash && (
            <p>
              Transaction: <code>{txHash}</code> —{" "}
              {receipt.isLoading ? "waiting for confirmation…" : receipt.isSuccess ? "confirmed." : receipt.isError ? "failed." : ""}
            </p>
          )}
          {writeError && (
            <p>Refused: {rejection ? REMEDY[rejection] : writeError.message}</p>
          )}
        </>
      ) : (
        <p>Connect a wallet (QoreX recommended) to use the vault.</p>
      )}

      <footer style={{ marginTop: "2rem", fontSize: 14, color: "#555" }}>
        <p>
          Honest limits: this app never signs post-quantum signatures in the browser and never
          asks for a private key or mnemonic. Above-threshold withdrawals are signed with the
          owner&apos;s own PQC key off-chain (SDK/CLI) and pasted as a signature. All EVM
          transactions need an open EVM authorisation window; the app cannot open one. Contract
          source and audit notes: see the repository README and AUDIT.md.
        </p>
      </footer>
    </main>
  );
}
