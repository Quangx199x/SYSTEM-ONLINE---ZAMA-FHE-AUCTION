import ("@nomicfoundation/hardhat-toolbox");
import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@typechain/hardhat";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import type { HardhatUserConfig } from "hardhat/config";
import { vars } from "hardhat/config";
import "solidity-coverage";

import "./tasks/accounts";
import "./tasks/FHECounter";

// Run 'npx hardhat vars setup' to see the list of variables that need to be set

const MNEMONIC: string = vars.get("MNEMONIC", "");
const INFURA_API_KEY: string = vars.get("INFURA_API_KEY", "");

// Define FHEVM_REPO_ROOT (adjust path to your local clone of https://github.com/zama-ai/fhevm)
const FHEVM_REPO_ROOT: string = vars.get("FHEVM_REPO_ROOT", "../fhevm"); // e.g., path to cloned repo root

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  namedAccounts: {
    deployer: 0,
  },
  etherscan: {
    apiKey: {
      sepolia: vars.get("ETHERSCAN_API_KEY", "8ICJ99N4XPVPJIVZS3K44U4IKQVTNEC6JI"),
    },
  },
  gasReporter: {
    currency: "USD",
    enabled: process.env.REPORT_GAS ? true : false,
    excludeContracts: [],
  },
  networks: {
    hardhat: {
      accounts: {
        mnemonic: MNEMONIC,
      },
      chainId: 31337,
    },
    anvil: {
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0/",
        count: 10,
      },
      chainId: 31337,
      url: "http://localhost:8545",
    },
    sepolia: {
      accounts: {
        mnemonic: MNEMONIC,
        path: "m/44'/60'/0'/0/",
        count: 10,
      },
      chainId: 11155111,
      url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
    },
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
  },
  solidity: {
    version: "0.8.27",
    settings: {
      metadata: {
        // Not including the metadata hash
        // https://github.com/paulrberg/hardhat-template/issues/31
        bytecodeHash: "none",
      },
      // Disable the optimizer when debugging
      // https://hardhat.org/hardhat-network/#solidity-optimizer-support
      optimizer: {
        enabled: true,
        runs: 800,
      },
      evmVersion: "cancun",
    },
    remappings: [
  // Map trực tiếp đến contracts folder
  `@fhevm/solidity=${FHEVM_REPO_ROOT}/library-solidity/contracts/`,
  // Hoặc nếu có sub lib/config: adjust theo tree (e.g., nếu lib là alias)
  `fhevm=${FHEVM_REPO_ROOT}/library-solidity/contracts/`,
  `@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/`,
],
  },
  typechain: {
    outDir: "types",
    target: "ethers-v6",
  },
};

export default config;