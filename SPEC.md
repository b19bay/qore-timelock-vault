# SPEC — Post-Quantum dApp entry: PQ Timelock Vault + guardian

**Kategori:** Post-Quantum dApp (Build Before Q-Day, QoreChain Developer Fest)
**Tujuan:** vault EVM yang menggabungkan timelock + guardian-cancel + daily
limit + ambang tanda tangan post-quantum. Tidak ada vault di fest yang
menggabungkan keempatnya (yang ada: hanya baca registry, hanya syarat sig PQ,
atau stunt tanpa fitur).
**Direktori kerja:** `~/workspace/qorechain-bounty/build-before-qday/dapp-vault/`
**Deadline event:** 2 Des 2026 23:59 UTC. Kerjakan dengan steady; kualitas dulu.

## Lingkungan & toolchain

- **Kontrak + tes: Foundry.** Binary tersedia di `~/workspace/tools/foundry/bin`
  (`forge`, `cast`; Foundry 1.9.0, solc 0.8.28). Buat proyek Foundry di
  `contracts/` di dalam direktori kerja (atau scaffold
  `create-qorechain-dapp@0.14.0 --template foundry` bila lebih nyaman — pilih
  satu, dokumentasikan). Tes WAJIB Foundry (syarat kategori: "Foundry or
  Hardhat tests").
- **Frontend: scaffold FRESH** `npx -y create-qorechain-dapp@0.14.0 qore-vault-app
  --template viem-wagmi --network testnet --yes` di `app/` di dalam direktori
  kerja. Auto-install scaffolder akan GAGAL (ia memanggil `pnpm`, tidak ada di
  VM) — itu normal; lanjutkan dengan `npm install` manual (~11 menit, pakai
  timeout minimal 15 menit), lalu `npm run build` harus exit 0.
- **JANGAN PERNAH membaca** `~/workspace/qorechain-bounty/build-before-qday/toolchain-test/`,
  `~/workspace/qorechain-bounty/build-before-qday/quantum-pass/`, atau kode
  proyek/entri lain mana pun — termasuk repo audit lokal
  `~/workspace/qorechain-bounty/qorechain-core/` dan catatan audit di
  `~/workspace/qorechain-bounty/`. Tulis semua baris dari spesifikasi ini.
  Kamu BOLEH membaca: dokumentasi resmi docs.qorechain.io, repo PUBLIK
  github.com/qorechain/qorechain-core (hanya untuk antarmuka precompile PQC —
  lihat §Precompile), dan definisi tipe di `node_modules` proyekmu SENDIRI.
- **JANGAN PERNAH menuliskan** kunci, seed phrase, mnemonic, atau kredensial
  apa pun ke file mana pun. Tidak ada `.env` berisi rahasia.
- **TANPA MAINNET.** Testnet `qorechain-diana` (EVM 9800) + devnet lokal saja.

## Jaringan (data persis)

- **Testnet publik `qorechain-diana`** (EVM chain ID 9800):
  - EVM JSON-RPC: `https://evm-testnet.qore.host`
  - Cosmos REST: `https://api-testnet.qore.host`
  - Cosmos RPC: `https://rpc-testnet.qore.host`
  - 1 QOR = 10^6 uqor (Cosmos) = 10^18 wei (EVM); 1 uqor = 10^12 wei.
- **Devnet lokal** (untuk tes deploy + E2E — kendali penuh):
  - chain-id `qorechain-devnet`; Cosmos RPC `http://localhost:26657`
  - binary `~/workspace/qorechain-bounty/bin/qorechaind`, wajib
    `LD_LIBRARY_PATH=$HOME/workspace/qorechain-bounty/bin/lib`
  - keyring home `~/workspace/qorechain-bounty/devnet/node1`,
    `--keyring-backend test`
  - **REST :1317 di devnet TIDAK aktif** — pakai RPC/CLI untuk devnet.
  - Port EVM JSON-RPC devnet: cari di `node1/config/app.toml` (biasanya 8545).
  - Fee minimum efektif: 50.000 uqor per tx native.
  - Akun dengan kunci PQC terdaftar WAJIB tanda tangan hybrid untuk tx native:
    buat tx `--generate-only`, lalu
    `tx pqc cosign <file.json> --from <nama> --pqc-key <nama> --fees 50000uqor
    --gas 400000`. Selalu verifikasi dengan `query tx <hash>` (DeliverTx code).
  - **EVM send hanya diterima bila akun punya ML-DSA-87 key terdaftar + EVM
    authorisation window terbuka.** Untuk deploy/interaksi EVM di devnet:
    daftarkan kunci PQC dulu (`tx pqc register-key-v2`), lalu buka window
    (`tx pqc open-evm-window` atau pesan setara — cek `qorechaind tx pqc --help`
    untuk nama perintah persis di binary ini). Window devnet: 600 blok, 5 tx
    (tunggu ~10 detik setelah open karena nonce akun maju).
- **Akun tes devnet (sudah didanai 10 QOR masing-masing, TANPA kunci PQC):**
  - `dv-owner` = `qor1rctgs8nz56le20pjhqx4f4jr52mrdulw0ptxzy` — pemilik vault.
  - `dv-guardian` = `qor14hxecqutn5v68nmeywt063a34ettkx60jpldp8` — guardian.
  - `dv-attacker` = `qor13sfwyr489cwg4djh6dp6ydehumkn5wrh0f0xkm` — penyerang
    untuk tes negatif.
  - Alamat EVM masing-masing = 20 byte yang sama dengan alamat `qor1`
    (decode bech32; jangan ditebak — hitung dari alamat di atas).
  - Akun Quantum Pass yang sudah punya kunci + window (bila perlu referensi):
    `qp-test1` = `qor1zyjeduu65sdvaglwvvm54rthjrxeprvezfl6vk`,
    `qp-test2` = `qor12zvllx0ly4vz723katfy0ts82rnevel3dlvs07`.

## Precompile PQC (verifikasi dari sumber publik sebelum memakai)

- `pqcVerify` = precompile **0x0A01** — memverifikasi tanda tangan ML-DSA-87
  terhadap kunci yang terdaftar.
- `pqcKeyStatus` = precompile **0x0A02** — membaca kunci PQC terdaftar milik
  sebuah alamat dari registry.
- **Verifikasi alamat + ABI kedua precompile dari docs.qorechain.io dan/atau
  repo publik github.com/qorechain/qorechain-core SEBELUM menulis kontrak.**
  Bila dokumentasi publik tidak memberi ABI yang cukup, catat itu sebagai
  temuan di handoff dan rancang kontrak dengan antarmuka precompile sebagai
  konstanta yang terdokumentasi + tes mock (lihat §Pengujian). Jangan mengarang
  ABI.

## Perilaku kontrak (satu kontrak utama: `PQTimelockVault.sol`)

### State & peran
- `owner` — ditetapkan di constructor; satu-satunya yang bisa deposit-atas-nama
  (siapa pun boleh deposit), antre penarikan, eksekusi penarikan, dan ganti
  guardian.
- `guardian` — ditetapkan di constructor (boleh `address(0)` = tanpa guardian);
  HANYA bisa membatalkan penarikan yang antre. Guardian TIDAK BISA menarik
  dana, mengubah owner, atau mengubah guardian.
- `timelockSeconds` — constructor param (deploy testnet: 86400 = 24 jam;
  tes: nilai kecil). Penarikan yang antre hanya bisa dieksekusi setelah
  `queuedAt + timelockSeconds`.
- `pqThreshold` — constructor param (deploy testnet: 1 QOR = 10^18 wei).
  Penarikan di ATAS ambang ini wajib tanda tangan ML-DSA-87 yang valid.
- `dailyLimit` — constructor param (deploy testnet: 5 QOR per 24 jam bergulir).
  Total penarikan yang dieksekusi dalam 24 jam terakhir tidak boleh melewati
  batas ini.

### Fungsi (nama fungsi bebas selama perilaku persis; dokumentasikan ABI final)
1. `deposit()` payable — siapa pun boleh deposit QOR (native). Emit `Deposited`.
2. `queueWithdrawal(address to, uint256 amount, bytes pqSignature)` — hanya
   owner. Membuat entri antrean (id, penerima, jumlah, waktu antre, status).
   Bila `amount > pqThreshold`, `pqSignature` WAJIB valid: tanda tangan
   ML-DSA-87 pemilik atas pesan penarikan (domain-separated: sertakan
   alamat kontrak, id antrean, penerima, jumlah, dan nonce — rancang skema
   pesannya dan dokumentasikan di README + komentar kode), diverifikasi
   on-chain via `pqcVerify` terhadap kunci pemilik dari `pqcKeyStatus`.
   Bila sig tidak valid → revert. Emit `WithdrawalQueued`.
3. `executeWithdrawal(uint256 id)` — hanya owner. Hanya setelah timelock
   lewat; hanya bila status masih `Queued`; hanya bila total eksekusi 24 jam
   terakhir + jumlah ini ≤ `dailyLimit`. Kirim dana ke penerima. Emit
   `WithdrawalExecuted`.
4. `cancelWithdrawal(uint256 id)` — hanya guardian (atau owner). Hanya bila
   status masih `Queued`. Emit `WithdrawalCancelled`. Dana tetap di vault.
5. `setGuardian(address newGuardian)` — hanya owner. Emit `GuardianChanged`.
6. View: `getWithdrawal(id)`, `queuedCount()`, `withdrawnLast24h()`,
   `balance()` (saldo vault), `owner()`, `guardian()`, parameter kontrak.
- **Keamanan wajib:** checks-effects-interactions; reentrancy guard pada
  execute; tidak ada fungsi yang memindahkan dana selain `executeWithdrawal`;
  tidak ada jalan pintas owner melewati timelock; guardian tidak bisa
  menjadi owner lewat fungsi apa pun.

### Event (minimal)
`Deposited(address indexed from, uint256 amount)`,
`WithdrawalQueued(uint256 indexed id, address indexed to, uint256 amount, uint256 executeAfter)`,
`WithdrawalExecuted(uint256 indexed id, address indexed to, uint256 amount)`,
`WithdrawalCancelled(uint256 indexed id, address indexed by)`,
`GuardianChanged(address indexed oldGuardian, address indexed newGuardian)`.

## Perilaku frontend (`app/`)
- Connect wallet (RainbowKit + QoreX, pola scaffold).
- Panel Deposit (jumlah + tombol, tunjukkan saldo vault + saldo user).
- Panel Queue Withdrawal (penerima, jumlah; bila di atas ambang PQ, tampilkan
  penjelasan bahwa penarikan ini butuh tanda tangan ML-DSA-87 + status kunci
  PQC pemilik; bila signing PQ dari browser belum memungkinkan, jelaskan
  dengan jujur cara melengkapi tanda tangan — JANGAN minta user menempelkan
  kunci privat/mnemonic ke halaman web).
- Daftar antrean: tiap entri dengan countdown timelock, tombol Execute
  (aktif setelah timelock lewat) dan Cancel (untuk guardian/owner).
- Panel Guardian: tampilkan guardian saat ini + ganti guardian (owner saja).
- Panel Daily limit: terpakai/sisa dalam 24 jam terakhir.
- Penjelasan jujur di UI: semua aksi EVM butuh EVM window terbuka (tautkan
  ke panduan membuka window; jangan klaim otomatisasi yang tidak ada).

## Pengujian (WAJIB lolos semua sebelum handoff)

1. **Foundry unit tests** (`forge test`, tanpa jaringan) — cakup SEMUA ini:
   - deposit menambah saldo + event.
   - queue di bawah ambang tanpa sig PQ berhasil.
   - queue di atas ambang tanpa sig / sig salah → revert.
   - queue di atas ambang dengan sig valid → berhasil (precompile di-mock
     dengan `vm.etch` pada alamat precompile ATAU antarmuka precompile
     di-inject sebagai dependensi yang bisa diganti di tes — pilih satu,
     dokumentasikan).
   - execute sebelum timelock → revert; setelah timelock → berhasil + dana
     sampai + event.
   - guardian cancel antrean → berhasil; non-guardian/non-owner cancel →
     revert; cancel setelah execute → revert.
   - guardian TIDAK BISA execute / queue / setGuardian (masing-masing revert).
   - daily limit: eksekusi kedua yang melewati batas 24 jam → revert;
     setelah 24 jam bergulir → berhasil lagi.
   - owner ganti guardian → berhasil; non-owner → revert.
   - reentrancy: penyerang (kontrak penerima jahat) tidak bisa menguras vault
     lewat execute (tes eksplisit).
2. **Tes fork testnet (bila feasible):** `forge test --fork-url
   https://evm-testnet.qore.host` untuk SATU tes jalur pqcVerify nyata
   (verifikasi tanda tangan nyata terhadap kunci nyata di testnet). Bila
   tidak feasible (mis. butuh kunci privat testnet), dokumentasikan alasannya
   dengan jujur dan ganti dengan tes mock yang ketat.
3. **Deploy + E2E di devnet:** deploy kontrak ke devnet EVM (dari `dv-owner`
   setelah registrasi kunci + buka window), lalu jalankan alur penuh:
   deposit → queue (di bawah ambang) → tunggu timelock (deploy tes dengan
   timelock pendek, mis. 60 detik) → execute → verifikasi saldo penerima;
   plus satu skenario cancel oleh guardian. Catat alamat kontrak + semua
   hash tx di handoff.
4. **Frontend:** `npm run build` exit 0 di `app/`; `npm run dev` HTTP 200.
5. **Revisi wajib:** setelah run pertama yang bekerja, lakukan minimal SATU
   revisi nyata (perbaikan berdasarkan hasil run pertama), lalu jalankan
   ulang semua tes.

## QCAI audit (persiapan — eksekusi butuh aksi user)
- Siapkan `contracts/flattened/` berisi source kontrak yang sudah di-flatten
  (untuk paste ke Dashboard Contract Auditor) + file `AUDIT.md` yang
  menjelaskan: apa itu QCAI audit 2 tahap (tahap 1 = audit source + catat
  skor/temuan/respons; tahap 2 = audit ulang setelah perbaikan), langkah
  persis menjalankan audit di `dashboard.qorechain.io/audit` (butuh sign-in
  akun Dashboard user; audit pertama/hari UTC gratis), dan checklist
  dokumentasi hasil (skor, temuan, respons per temuan, PDF).
- Kamu TIDAK BISA menjalankan auditnya sendiri (butuh akun Dashboard user) —
  siapkan semua artefaknya dan flag eksekusinya sebagai aksi user di handoff.
  JANGAN klaim audit sudah jalan bila belum.

## File yang harus ada di repo
- `README.md` — apa itu, kenapa beda (timelock + guardian + daily limit +
  ambang PQ — kombinasi yang belum ada), arsitektur, cara menjalankan,
  cara menguji, cara deploy (devnet + testnet), skema pesan tanda tangan PQ,
  batasan yang diketahui (termasuk status QCAI + batasan signing QoreX),
  kredit: template `create-qorechain-dapp` + SDK QoreChain + Foundry.
- `AI_USAGE.md` — dokumentasikan workflow AI-native dengan jujur dan spesifik
  (syarat special award Best AI-Native Build $500).
- `AUDIT.md` — persiapan QCAI (lihat atas).
- `LICENSE` — MIT, diketik dari ingatan, dengan baris identifier SPDX.
- `.gitignore` — `node_modules/`, `dist/`, `out/`, `cache/`, `broadcast/`,
  `.env`, dan sejenisnya.
- TIDAK ADA file berisi kunci/seed/kredensial.

## Kegagalan yang harus dihindari (inokulasi — P-36)
- Jangan mengarang ABI precompile — verifikasi dari sumber publik dulu.
- Jangan mengklaim sesuatu yang tidak diuji (mis. jangan klaim "pqcVerify
  nyata teruji" bila baru mock — tulis dengan jujur di mana tiap hal diuji).
- Jangan menyembunyikan error chain — tampilkan apa adanya.
- Jangan mengarang data (skor, status, hash) — semua dari run nyata.
- Jangan memakai mainnet, dana nyata, atau layanan berbayar apa pun.
- Jangan memberi guardian kekuasaan memindahkan dana — guardian hanya cancel.

## Format handoff ke koordinator
- Direktori entri + daftar file utama + alamat kontrak devnet.
- Hasil tiap tes (perintah persis + output ringkas + PASS/FAIL).
- Hash tx devnet untuk deploy + alur E2E + hasil tiap langkah.
- Status verifikasi precompile (alamat + ABI dari sumber apa).
- Status QCAI (artefak siap; eksekusi menunggu aksi user).
- Batasan yang diketahui + apa yang masih butuh aksi user.
- Saran judul entri + satu kalimat deskripsi untuk halaman proyek.
