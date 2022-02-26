const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("Testing gAkitaERC20.sol", function () {
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
      await expect(
        vaultOwned.setVault("0x831654134062Dc00fe93bA281AF75a8Ffa740787")
      ).to.be.revertedWith("Timelocked");

      const vaultAddress = await vaultOwned.vault();
      expect(vaultAddress).to.equal(
        "0x0000000000000000000000000000000000000000"
      );
    });

    it("Should be able to open timelock", async () => {
      await vaultOwned.openTimeLock();

      const blockNumber = await ethers.provider.getBlockNumber();
      const block = await ethers.provider.getBlock(blockNumber);
      const timestampBefore = block.timestamp;

      const timeLock = await vaultOwned.timelock();
      expect(timeLock).to.equal(timestampBefore + 172800);
    });

    it("Should not be able to set vault during timelock", () => {});

    it("Should be able to set valut after timelock expired", () => {});

    it("Should add timelock after setVault", () => {});

    it("Should be able to cancel unlock", () => {});
  });
});
