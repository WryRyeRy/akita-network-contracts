const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("Testing Treasury.sol", function () {
  let treasury;
  let akita;
  let wavax; //reserve token
  let wavaxakita; //liqudity token
  let anotherreserve;
  let sgakita;
  let owner;

  // quick fix to let gas reporter fetch data from gas station & coinmarketcap
  before((done) => {
    setTimeout(done, 2000);
  });

  describe("AkitaTreasury", function () {
    it("Should deploy AkitaTreasury and setup state", async function () {
      const [o, another] = await ethers.getSigners();
      owner = o;

      const TreasuryContract = await ethers.getContractFactory("AkitaTreasury");

      akita = await (await ethers.getContractFactory("_AKITA")).deploy();
      wavax = await (await ethers.getContractFactory("_WAVAX")).deploy();
      wavaxakita = await (
        await ethers.getContractFactory("_WAVAXAKITA")
      ).deploy();
      sgakita = await (await ethers.getContractFactory("_SGAKITA")).deploy();
      anotherreserve = await (
        await ethers.getContractFactory("_ANOTHERRESERVE")
      ).deploy();

      treasury = await TreasuryContract.deploy(
        akita.address,
        wavax.address,
        wavaxakita.address,
        0
      );

      await treasury.queue(0, owner.address);
      await treasury.queue(2, anotherreserve.address);
      await treasury.queue(7, owner.address);
      await treasury.queue(9, owner.address);
      await treasury.toggle(0, owner.address, owner.address);
      await treasury.toggle(2, anotherreserve.address, owner.address);
      await treasury.toggle(7, owner.address, owner.address);
      await treasury.toggle(9, sgakita.address, owner.address);

      const ownerWavaxBalance = await wavax.balanceOf(owner.address);
      const ownerReserveBalance = await anotherreserve.balanceOf(owner.address);
      await wavax.approve(treasury.address, ownerWavaxBalance);
      await anotherreserve.approve(treasury.address, ownerReserveBalance);

      await treasury.deposit(ownerWavaxBalance, wavax.address, 0);
      await treasury.deposit(
        ownerReserveBalance.sub(50000),
        anotherreserve.address,
        0
      );
    });

    it("Should not be able to repay debt using other token", async () => {
      await treasury.incurDebt(50000, wavax.address);

      const debt = await treasury.debtorBalance(owner.address, wavax.address);
      expect(debt).to.equal(50000);

      await expect(treasury.repayDebtWithReserve(50000, anotherreserve.address))
        .to.be.reverted;

      const debtAfter = await treasury.debtorBalance(
        owner.address,
        wavax.address
      );
      expect(debtAfter).to.equal(50000);
    });
  });
});
