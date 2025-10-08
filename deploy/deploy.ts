Uếimport { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

// Deployment function: Async, nhận hre (environment)
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deployer } = await getNamedAccounts();  // Use namedAccounts from config (deployer: 0)

  console.log("Deploying FHEAuction with the account:", deployer);

  // Params cho constructor
  const minDeposit = BigInt(10_000_000_000_000_000n);  // 0.01 ETH in wei (BigInt cho ethers v6)
  const pauserSet = "0x0000000000000000000000000000000000000000";  // Address(0) optional
  const beneficiary = deployer;  // Deployer làm beneficiary

  // Deploy with hardhat-deploy (auto save artifacts, tags)
  await deployments.deploy("FHEAuction", {
    from: deployer,
    args: [minDeposit, pauserSet, beneficiary],
    log: true,  // Log tx
    autoMine: true,  // Auto mine on local (test)
  });

  console.log("FHEAuction deployed successfully!");
};

export default func;

// Tags to run selective (e.g., npx hardhat deploy --tags FHEAuction)
func.tags = ["FHEAuction"];
func.dependencies = []; 
