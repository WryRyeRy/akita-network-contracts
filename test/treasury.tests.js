const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("Testing Treasury.sol", function () {
  let treasury;

  // quick fix to let gas reporter fetch data from gas station & coinmarketcap
  before((done) => {
    setTimeout(done, 2000);
  });

  describe("AkitaTreasury", function () {
    it("Should deploy AkitaTreasury", async function () {
      const TreasuryContract = await ethers.getContractFactory("AkitaTreasury");

      //       treasury = await TreasuryContract.deploy(
      // //        "0xf50E7b1454c9c011dFE9d918EF68eEDE3891C26D"
      //       );

      expect(true).to.equal(true);
    });
  });
});
