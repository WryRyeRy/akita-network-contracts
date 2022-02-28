const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("Testing gAkitaERC20.sol", function () {
  const address = "0x831654134062Dc00fe93bA281AF75a8Ffa740787";
  const zeroAddress = "0x0000000000000000000000000000000000000000";
  let vaultOwned;

  // quick fix to let gas reporter fetch data from gas station & coinmarketcap
  before((done) => {
    setTimeout(done, 2000);
  });

  describe("VaultOwned", function () {
    it("Timelock should be 0 when deploying", async function () {
      const VaultOwned = await ethers.getContractFactory("VaultOwned");

      vaultOwned = await VaultOwned.deploy();

      const timeLock = await vaultOwned.timelock();

      expect(timeLock).to.equal(0);
    });

    it("Should not be able to change valut address if timelock is 0", async () => {
      await expect(vaultOwned.setVault(address)).to.be.revertedWith(
        "Timelocked"
      );

      const vaultAddress = await vaultOwned.vault();
      expect(vaultAddress).to.equal(zeroAddress);
    });

    it("Should be able to open timelock", async () => {
      await vaultOwned.openTimeLock();

      const timeLock = await vaultOwned.timelock();
      expect(timeLock).to.equal((await getBlockTime()) + 172800);
    });

    it("Should not be able to set vault during timelock", async () => {
      await expect(vaultOwned.setVault(address)).to.be.revertedWith(
        "Timelocked"
      );

      const vaultAddress = await vaultOwned.vault();
      expect(vaultAddress).to.equal(zeroAddress);
    });

    it("Should be able to set valut after timelock expired", async () => {
      await ethers.provider.send("evm_mine", [(await getBlockTime()) + 432000]); // move time 4 days

      await vaultOwned.setVault(address);

      const vaultAddress = await vaultOwned.vault();
      expect(vaultAddress).to.equal(address);
    });

    it("Should add timelock to 0 after setVault", async () => {
      const timeLock = await vaultOwned.timelock();

      expect(timeLock).to.equal(0);
    });

    it("Should be able to cancel unlock", async () => {
      await vaultOwned.openTimeLock();

      let timeLock = await vaultOwned.timelock();
      expect(timeLock).to.equal((await getBlockTime()) + 172800);

      await vaultOwned.cancelTimeLock();

      timeLock = await vaultOwned.timelock();
      expect(timeLock).to.equal(0);
    });
  });

  const getBlockTime = async () => {
    const blockNumber = await ethers.provider.getBlockNumber();
    const block = await ethers.provider.getBlock(blockNumber);
    return block.timestamp;
  };
});
