git clone https://github.com/yourusername/fhe-auction-project.git
npm install
npx hardhat compile
npx hardhat node
npx hardhat test
npx hardhat deploy --network sepolia
npx hardhat verify --network sepolia 0x76044483b2387720EA449243Eb3d1eE1f5c86fbE "10000000000000000" "0x0000000000000000000000000000000000000000" "0x091F5393DDeBA93C44957A0Bb1B7a63c378cEB4F"
npx hardhat console --network sepolia
javascript
npx hardhat test

# FHEAuction: Blind Auction with FHEVM on Sepolia

![Solidity](https://img.shields.io/badge/Solidity-0.8.27-blue.svg)
![FHEVM](https://img.shields.io/badge/FHEVM-v0.9.0-orange.svg)
![Sepolia Testnet](https://img.shields.io/badge/Network-Sepolia-green.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

FHEAuction is a secure blind auction smart contract built using Fully Homomorphic Encryption (FHE) via Zama's FHEVM on Ethereum Sepolia testnet. Bids are encrypted on-chain, ensuring full privacy during the bidding phase—no one knows the bid values until decryption after the auction ends. This prevents front-running and shill bidding, making it ideal for confidential DeFi applications.

Multi-round auctions run automatically every 24 hours, with auto-refunds for losers and payments to the beneficiary.

**Deployed at:** `0x76044483b2387720EA449243Eb3d1eE1f5c86fbE` (Verified: Oct 7, 2025)

> ⚠️ **Note:** Zama Relayer Testnet degraded (92% uptime as of Oct 7, 2025)—decryption testing delayed. Check status: Zama Status.

---

## Table of Contents
- [Key Features](#key-features)
- [Tech Stack](#tech-stack)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Testing](#testing)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Key Features
- **Privacy-Preserving Bidding:** Encrypted bids using `euint64` and homomorphic operations (`FHE.gt`, `FHE.select`). No on-chain decryption during bidding.
- **Multi-Round Auction:** Auto-starts new rounds post-finalize; fixed 24-hour duration.
- **Secure Decryption:** Off-chain reveal via Zama Oracle callback (`onDecryptionCallback`); verifies all bids to find winner with tie-breaker (highest deposit).
- **Auto-Refunds & Payments:** Losers get full deposits back; winner pays `min(winningBid, deposit)` to beneficiary, refunds excess.
- **Emergency Controls:** Owner can pause/unpause, emergency end (after 24h delay), or cancel.
- **Signed Verification:** Bids require EIP-712 signed public keys for integrity.
- **Gas Efficient:** O(1) bidder tracking; single decode in callback.

---

## Tech Stack
- **Language:** Solidity ^0.8.24 (Compiled: v0.8.27, Optimizer: 800 runs)
- **FHE Library:** `@fhevm/solidity` (v0.9.0)
- **Security:** OpenZeppelin (EIP712, ECDSA, ReentrancyGuard)
- **Deployment:** Hardhat + hardhat-deploy
- **Network:** Ethereum Sepolia Testnet (EVM: Cancun)
- **Off-Chain Tools:** TFHE-rs (Rust) for bid encryption; Ethers.js for interactions

---

## Quick Start

### Prerequisites
- Node.js >= 18
- Yarn or NPM
- MetaMask (with Sepolia ETH from faucet)
- Git

### Installation
```bash
git clone https://github.com/yourusername/fhe-auction-project.git
cd fhe-auction-project
npm install # or yarn install
```

### Environment Variables
Create a `.env` file:
```env
MNEMONIC="your 12-word mnemonic"
INFURA_API_KEY="your infura key"
ETHERSCAN_API_KEY="your etherscan key"
```

### Compile
```bash
npx hardhat compile
```

### Local Testing
```bash
npx hardhat node
# In another terminal
npx hardhat test
```

### Deployment to Sepolia
```bash
npx hardhat deploy --network sepolia
```
Constructor args: `minDeposit` (e.g., 0.01 ETH in wei), `pauserSet` (0x0), `beneficiary` (your address).

### Verify on Etherscan
```bash
npx hardhat verify --network sepolia 0x76044483b2387720EA449243Eb3d1eE1f5c86fbE "10000000000000000" "0x0000000000000000000000000000000000000000" "0x091F5393DDeBA93C44957A0Bb1B7a63c378cEB4F"
```

---

## Usage

### Placing a Bid (Off-Chain Prep)
1. **Encrypt Bid:** Use TFHE-rs (Rust) to encrypt your bid amount (`uint64`).
	```rust
	// Example with tfhe-rs
	use tfhe::prelude::*;
	let bid = 1_000_000_000u64; // e.g., 1 ETH in gwei
	let encrypted_bid = encrypt(bid, public_key); // Generate externalEuint64
	```
2. **Sign Public Key:** Sign the FHE public key with EIP-712.
3. **Submit Tx:** Call `bid(encryptedBid, proof, publicKey, signature)` with ETH deposit (>= minDeposit).

### Finalizing Auction
- Owner calls `requestFinalize()` after 24h.
- Oracle triggers `onDecryptionCallback` → Auto refund, pay beneficiary, start next round.

### Interact via Console
```js
npx hardhat console --network sepolia
const auction = await ethers.getContractAt("FHEAuction", "0x76044483b2387720EA449243Eb3d1eE1f5c86fbE");
await auction.getMinBidDeposit(); // View min deposit
```

---

## Testing
- **Unit Tests:** In `test/FHEAuction.test.ts` (mock FHE ops with Hardhat plugin).
- **FHE Simulation:** `npx hardhat fhevm check-fhevm-compatibility --network localhost`.
- **Edge Cases:** No bidders, ties, emergency, multi-bids.
- **Run tests:**
	```bash
	npx hardhat test
	```

---

## Development
- **Scripts:** `scripts/deploy.ts` for deployment.
- **Tasks:** Custom tasks in `tasks/` (e.g., simulate callback).
- **Config:** `hardhat.config.ts` with FHEVM remappings.

### Building Locally
```bash
npx hardhat flatten contracts/FHEAuction.sol > flattened.sol
```

---

## Contributing
1. Fork the repo.
2. Create a feature branch:
	```bash
	git checkout -b feature/AmazingFeature
	```
3. Commit changes:
	```bash
	git commit -m 'Add some AmazingFeature'
	```
4. Push:
	```bash
	git push origin feature/AmazingFeature
	```
5. Open a Pull Request.

**Guidelines:**
- Follow Solidity style guide.
- Add tests for new features.
- Update README if needed.

---

## License
This project is licensed under the MIT License - see the LICENSE file for details.

---

## Acknowledgments
- Zama FHEVM: For the revolutionary FHE tech—[docs.zama.ai](https://docs.zama.ai).
- OpenZeppelin: Secure contracts foundation.
- Hardhat: Amazing dev environment.

Guidelines:Follow Solidity style guide.
Add tests for new features.
Update README if needed.

 LicenseThis project is licensed under the MIT License - see the LICENSE file for details. AcknowledgmentsZama FHEVM: For the revolutionary FHE tech—docs.zama.ai.
OpenZeppelin: Secure contracts foundation.
Hardhat: Amazing dev environment.

