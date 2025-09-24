import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

// Deployment function: Async, nhận hre (environment)
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deployer } = await getNamedAccounts();  // Sử dụng namedAccounts từ config (deployer: 0)

  console.log("Deploying FHEAuction with the account:", deployer);

  // Params cho constructor
  const minDeposit = BigInt(10_000_000_000_000_000n);  // 0.01 ETH in wei (BigInt cho ethers v6)
  const pauserSet = "0x0000000000000000000000000000000000000000";  // Address(0) optional
  const beneficiary = deployer;  // Deployer làm beneficiary

  // Deploy với hardhat-deploy (tự động save artifacts, tags)
  await deployments.deploy("FHEAuction", {
    from: deployer,
    args: [minDeposit, pauserSet, beneficiary],
    log: true,  // Log chi tiết tx
    autoMine: true,  // Auto mine trên local (nếu test)
  });

  console.log("FHEAuction deployed successfully!");
};

export default func;

// Tags để run selective (e.g., npx hardhat deploy --tags FHEAuction)
func.tags = ["FHEAuction"];
func.dependencies = [];  // Không phụ thuộc script khác