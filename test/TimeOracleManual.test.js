const _ = require("lodash/fp");
const chai = require("chai");
const { ethers, deployments, getNamedAccounts } = require("hardhat");
const { expect } = chai;
const { TOKEN_EXAMPLE, stringToBytes32, KYC_DATA } = require("./utils");

const setupTest = deployments.createFixture(
  async ({ deployments, getNamedAccounts, ethers }) => {
    const { deploy } = deployments;
    await deployments.fixture([], { fallbackToGlobal: false });

    const { custodianContractOwner } = await getNamedAccounts();

    const { address: timeOracleManualAddress } = await deploy(
      "TimeOracleManual",
      {
        from: custodianContractOwner,
        args: [],
      }
    );

    const escrowManager = await deploy("EscrowManager", {
      from: custodianContractOwner,
      proxy: {
        proxyContract: "OpenZeppelinTransparentProxy",
        execute: {
          methodName: "initialize",
          args: [],
        },
      },
    });
    const escrowManagerAddress = escrowManager.address;
    const { address: tokenCreatorTvTAddress } = await deploy(
      "TokenCreatorTvT",
      {
        from: custodianContractOwner,
        args: [escrowManagerAddress],
      }
    );

    const deployResult = await deploy("CustodianContract", {
      from: custodianContractOwner,
      proxy: {
        proxyContract: "OpenZeppelinTransparentProxy",
        execute: {
          methodName: "initialize",
          args: [tokenCreatorTvTAddress, timeOracleManualAddress],
        },
      },
    });
    const custodianContractAddress = deployResult.address;

    const TokenCreatorTvT = await ethers.getContract(
      "TokenCreatorTvT",
      custodianContractOwner
    );

    await TokenCreatorTvT.transferOwnership(custodianContractAddress);

    const EscrowManager = await ethers.getContract(
      "EscrowManager",
      custodianContractOwner
    );

    await EscrowManager.setCustodianContract(custodianContractAddress);

    await deploy("PaymentToken", {
      from: custodianContractOwner,
      args: [],
    });

    return {};
  }
);

describe("TimeOracleManual", function () {
  let CustodianContract;
  let CustodianContractIssuer;
  let TokenContract;
  let TokenContractNonIssuer;
  let TokenContractSubscriber;
  let PaymentToken;
  let EscrowManager;
  let EscrowManagerIssuer;
  let EscrowManagerSubscriber;
  let TimeOracleManual;

  const prepareIssuanceSwap = async (amount = 1) => {
    const { issuer, subscriber } = await getNamedAccounts();

    await TokenContract["issue(address,uint256)"](subscriber, amount);
    await EscrowManagerIssuer.depositCollateral(issuer, {
      value: amount * 3,
    });
    const PaymentTokenSubscriber = await ethers.getContract(
      "PaymentToken",
      subscriber
    );
    await PaymentTokenSubscriber.approve(EscrowManager.address, amount * 2);
  };

  const prepareRedemptionSwap = async (orderId) => {
    await prepareIssuanceSwap();

    await EscrowManager.swapIssuance(orderId);

    await TimeOracleManual.moveForwardByDays(30);
    await TimeOracleManual.moveForwardBySeconds(1);

    const { issuer, subscriber } = await getNamedAccounts();

    await TokenContractSubscriber["redeem(address,uint256)"](subscriber, 1);

    const PaymentTokenIssuer = await ethers.getContract("PaymentToken", issuer);

    await PaymentTokenIssuer.approve(EscrowManager.address, 3);
  };

  beforeEach(async () => {
    await setupTest();
    const {
      custodianContractOwner,
      custodian,
      issuer,
      subscriber,
      subscriber2,
      kycProvider,
      insurer,
    } = await getNamedAccounts();
    CustodianContract = await ethers.getContract(
      "CustodianContract",
      custodianContractOwner
    );
    CustodianContractIssuer = await ethers.getContract(
      "CustodianContract",
      issuer
    );

    PaymentToken = await ethers.getContract(
      "PaymentToken",
      custodianContractOwner
    );
    await CustodianContract.addIssuer("countryCode", issuer);
    await PaymentToken.transfer(subscriber, 1000);
    await CustodianContract.addPaymentToken(PaymentToken.address);
    await CustodianContractIssuer.publishToken({
      ...TOKEN_EXAMPLE,
      name: "Test Token",
      symbol: "TT1",
      paymentTokens: [PaymentToken.address],
      issuanceSwapMultiple: [2],
      redemptionSwapMultiple: [3],
      earlyRedemption: false,
      issuerPrimaryAddress: issuer,
      collateral: 3,
      issuerSettlementAddress: issuer,
    });
    const tokens = await CustodianContract.getTokens(issuer);
    TokenContract = await ethers.getContractAt(
      "TokenTvT",
      tokens[0].address_,
      issuer
    );
    TokenContractNonIssuer = await ethers.getContractAt(
      "TokenTvT",
      tokens[0].address_,
      custodianContractOwner
    );
    TokenContractSubscriber = await ethers.getContractAt(
      "TokenTvT",
      tokens[0].address_,
      subscriber
    );
    await CustodianContractIssuer.updateKyc(issuer, subscriber, KYC_DATA);
    await CustodianContractIssuer.updateKyc(issuer, subscriber2, KYC_DATA);
    await CustodianContractIssuer.addWhitelist(tokens[0].address_, [
      subscriber,
      subscriber2,
    ]);

    EscrowManager = await ethers.getContract(
      "EscrowManager",
      custodianContractOwner
    );
    EscrowManagerIssuer = await ethers.getContract("EscrowManager", issuer);
    EscrowManagerSubscriber = await ethers.getContract(
      "EscrowManager",
      subscriber
    );
    TimeOracleManual = await ethers.getContract(
      "TimeOracleManual",
      custodianContractOwner
    );

    await TimeOracleManual.enableManualMode();

    await prepareIssuanceSwap();
    await EscrowManagerIssuer.swapIssuance(0);

    await PaymentToken.transfer(issuer, 1000);
  });

  describe("move time forward manually", async () => {
    it("cannot swap the order if conditions are not met before expiry", async () => {
      const { subscriber } = await getNamedAccounts();

      await TimeOracleManual.moveForwardByDays(30);
      await TimeOracleManual.moveForwardBySeconds(1);

      await TokenContractSubscriber["redeem(address,uint256)"](subscriber, 1);

      await expect(EscrowManagerIssuer.swapRedemption(1)).to.be.revertedWith(
        "full escrow conditions are not met before expiry"
      );
    });

    it("swaps the order if conditions are met after expiry", async () => {
      await prepareRedemptionSwap(1);

      await TimeOracleManual.moveForwardByDays(2);
      await TimeOracleManual.moveForwardBySeconds(1);

      await expect(EscrowManagerIssuer.swapRedemption(2)).not.to.be.reverted;
    });
  });

  describe("access control", async () => {
    it("doesn't allow time shifting for non-admin addresses", async () => {
      const { issuer } = await getNamedAccounts();

      const TimeOracleManualIssuer = await ethers.getContract(
        "TimeOracleManual",
        issuer
      );

      await expect(
        TimeOracleManualIssuer.moveForwardByDays(2)
      ).to.be.revertedWith("missing role");
    });

    it("allows time shifting for admin addresses", async () => {
      const { issuer } = await getNamedAccounts();

      await TimeOracleManual.grantRole(ethers.constants.HashZero, issuer);

      const TimeOracleManualIssuer = await ethers.getContract(
        "TimeOracleManual",
        issuer
      );

      await expect(TimeOracleManualIssuer.moveForwardByDays(2)).not.to.be
        .reverted;
    });
  });
});
