// Sign a PQTimelockVault above-threshold withdrawal message with an ML-DSA-87
// secret key, using the official @qorechain/sdk (offline).
//
// Usage:
//   npm install            # once, in this directory (installs @qorechain/sdk)
//   node sign-withdrawal.cjs <secret-key-hex-file> <message-hash-hex> [pubkey-hex]
//
//   <secret-key-hex-file>  the .dilithium file `qorechaind tx pqc gen-key`
//                          wrote (4,896-byte secret key as a hex string).
//   <message-hash-hex>     the 32-byte message hash from the vault's
//                          pqMessageHash(id, to, amount, nonce) — the dApp
//                          shows it (with a Copy button) when a withdrawal
//                          is above the PQ threshold, or read it with:
//                            cast call <vault> 'pqMessageHash(uint256,address,uint256,uint256)(bytes32)' \
//                              <nextId> <to> <amountWei> <pqNonce> --rpc-url <rpc>
//   [pubkey-hex]           optional: the owner's registered public key
//                          (2,592 bytes hex) for an offline verification
//                          before you send the transaction. Get it with:
//                            cast call 0x0000000000000000000000000000000000000a02 \
//                              'pqcKeyStatus(address)(bool,uint8,bytes,bool)' <owner> --rpc-url <rpc>
//
// The script prints the signature hex (4,627 bytes) and, when a pubkey is
// given, an offline verification result. Paste the SIGNATURE (not the key)
// into the dApp's queue-withdrawal form.
//
// SECURITY: the secret key is read into memory only and never written
// anywhere by this script. Run it only on your own machine, only with your
// own devnet/testnet keys. Never paste a mainnet secret key into any script,
// and never paste a secret key or mnemonic into the dApp or anywhere else.
const { pqcSign, pqcVerify } = require("@qorechain/sdk");
const { readFileSync } = require("node:fs");

const [skFile, msgHex, pubkeyHex] = process.argv.slice(2);
if (!skFile || !msgHex) {
  console.error(
    "usage: node sign-withdrawal.cjs <secret-key-hex-file> <message-hash-hex> [pubkey-hex]",
  );
  process.exit(1);
}

const sk = Buffer.from(readFileSync(skFile, "utf8").trim(), "hex");
const msg = Buffer.from(msgHex.replace(/^0x/, ""), "hex");
console.log("secret key length:", sk.length, "bytes | message length:", msg.length, "bytes");
if (sk.length !== 4896) throw new Error("secret key must be 4896 bytes (ML-DSA-87)");
if (msg.length !== 32) throw new Error("message hash must be 32 bytes");

const sig = pqcSign(sk, msg);
console.log("signature length:", sig.length, "bytes");
if (pubkeyHex) {
  const pk = Buffer.from(pubkeyHex.replace(/^0x/, ""), "hex");
  if (pk.length !== 2592) throw new Error("public key must be 2592 bytes (ML-DSA-87)");
  console.log("offline verify (SDK pqcVerify):", pqcVerify(pk, msg, sig));
}
console.log("SIG:" + Buffer.from(sig).toString("hex"));
