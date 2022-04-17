const hre = require("hardhat");
const { ethers, upgrades } = hre;

const deployBeacon = require("./deployBeacon.js");

module.exports = {
  deployBeacon: async () => {
    process.hhCompiled ? null : await hre.run("compile");
    process.hhCompiled = true;
    return await deployBeacon([2], await ethers.getContractFactory("Thread"));
  },

  // Doesn't use ThreadDeployer in order to prevent the need to fake an entire Crowdfund
  deployTestThread: async (governor) => {
    const TestERC20 = await ethers.getContractFactory("TestERC20");
    const token = await TestERC20.deploy("Test Token", "TERC");

    const FrabricERC20 = require("./deployFrabricERC20.js");
    const erc20Beacon = await FrabricERC20.deployBeacon();
    const { auction, erc20 } = await FrabricERC20.deploy(erc20Beacon, null);

    const TestFrabric = await ethers.getContractFactory("TestFrabric");
    const frabric = await TestFrabric.deploy();
    await frabric.setGovernor(governor, 2);

    const beacon = await module.exports.deployBeacon();
    const Thread = await ethers.getContractFactory("Thread");
    const thread = await upgrades.deployBeaconProxy(
      beacon.address,
      Thread,
      [
        "1 Main Street",
        erc20.address,
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        frabric.address,
        governor,
        [frabric.address]
      ]
    );

    await erc20.initialize(
      "1 Main Street",
      "TTHR",
      "100000000000000000000",
      false,
      frabric.address,
      token.address,
      auction.address
    );

    return { token, frabric, erc20, beacon, thread };
  }
};

if (require.main === module) {
  module.exports.deployTestThread(ethers.constants.AddressZero)
    .then(contracts => console.log("Thread: " + contracts.thread.address))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
