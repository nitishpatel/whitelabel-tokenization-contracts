//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./TokenBase.sol";
import "./TokenTvTTypes.sol";
import "./EscrowManager.sol";

contract TokenTvT is TokenBase {
  string public constant VERSION = "0.0.1";
  string public constant TYPE = "TokenTvT";

  address[] internal _paymentTokens;
  uint256[] internal _issuanceSwapMultiple;
  uint256[] internal _redemptionSwapMultiple;
  uint256 internal _maturityPeriod;
  uint256 internal _settlementPeriod;
  uint256 internal _collateral;

  mapping(address => mapping(uint256 => uint256))
    internal _issuedTokensByMaturityBucket;
  mapping(address => uint256[]) internal _issuedTokensMaturityBuckets;

  EscrowManager public escrowManager;

  event IssuanceEscrowInitiated(
    uint256 orderId,
    address tradeToken,
    uint256 tradeTokenAmount,
    address tradeTokenDestination,
    address issuerAddress,
    address paymentToken,
    uint256 paymentTokenAmount,
    address paymentTokenDestination,
    address investorAddress,
    uint256 collateral,
    uint256 timeout
  );

  event RedemptionEscrowInitiated(
    uint256 orderId,
    address tradeToken,
    uint256 tradeTokenAmount,
    address tradeTokenDestination,
    address issuerAddress,
    address paymentToken,
    uint256 paymentTokenAmount,
    address paymentTokenDestination,
    address investorAddress,
    uint256 collateral,
    uint256 timeout
  );

  constructor(
    TokenTvTInput memory input,
    address custodianContract,
    address escrowManagerAddress
  )
    TokenBase(input.name, input.symbol, input.maxTotalSupply, custodianContract)
  {
    _paymentTokens = input.paymentTokens;
    _issuanceSwapMultiple = input.issuanceSwapMultiple;
    _redemptionSwapMultiple = input.redemptionSwapMultiple;
    _maturityPeriod = input.maturityPeriod;
    _settlementPeriod = input.settlementPeriod;
    _collateral = input.collateral;
    escrowManager = EscrowManager(escrowManagerAddress);
  }

  function issue(address subscriber, uint256 value) public override onlyIssuer {
    return issue(subscriber, owner(), subscriber, value);
  }

  function issue(
    address subscriber,
    address paymentTokenDestination,
    address tradeTokenDestination,
    uint256 value
  ) public onlyIssuer {
    if (_isFinalized == true) {
      throwError(ErrorCondition.TOKEN_IS_FINALIZED);
    }

    if (_maxTotalSupply < totalSupply() + value) {
      throwError(ErrorCondition.MAX_TOTAL_SUPPLY_MINT);
    }

    bytes1 reasonCode = _custodianContract.canIssue(
      address(this),
      subscriber,
      value
    );

    address tokenOwner = owner();

    if (reasonCode != ReasonCodes.TRANSFER_SUCCESS) {
      emit IssuanceFailure(subscriber, value, reasonCode);
    } else {
      _mint(tokenOwner, value);
      increaseAllowance(address(escrowManager), value);
      EscrowOrder memory escrowOrder = EscrowOrder({
        tradeToken: address(this),
        tradeTokenAmount: value,
        tradeTokenDestination: tradeTokenDestination,
        issuerAddress: tokenOwner,
        paymentToken: _paymentTokens[0],
        paymentTokenAmount: _issuanceSwapMultiple[0] * value,
        paymentTokenDestination: paymentTokenDestination,
        investorAddress: subscriber,
        collateral: _collateral * value,
        timeout: _settlementPeriod
      });
      uint256 orderId = escrowManager.startIssuanceEscrow(escrowOrder);
      emit IssuanceEscrowInitiated(
        orderId,
        escrowOrder.tradeToken,
        escrowOrder.tradeTokenAmount,
        escrowOrder.tradeTokenDestination,
        escrowOrder.issuerAddress,
        escrowOrder.paymentToken,
        escrowOrder.paymentTokenAmount,
        escrowOrder.paymentTokenDestination,
        escrowOrder.investorAddress,
        escrowOrder.collateral,
        escrowOrder.timeout
      );
    }
  }

  function onIssue(address subscriber, uint256 value) external {
    if (msg.sender != address(escrowManager)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    uint256 timestamp = _custodianContract.getTimestamp();

    _issuedTokensByMaturityBucket[subscriber][timestamp] += value;
    _issuedTokensMaturityBuckets[subscriber].push(timestamp);

    emit Issued(subscriber, value, ReasonCodes.TRANSFER_SUCCESS);
  }

  function onRedeem(address subscriber, uint256 value) external {
    if (msg.sender != address(escrowManager)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    uint256 i = 0;
    uint256 remainingValue = value;
    uint256[] storage maturityBuckets = _issuedTokensMaturityBuckets[
      subscriber
    ];

    while (
      i < maturityBuckets.length &&
      remainingValue > 0 &&
      (maturityBuckets[i] + _maturityPeriod < _custodianContract.getTimestamp())
    ) {
      uint256 currentBucketBalance = _issuedTokensByMaturityBucket[subscriber][
        maturityBuckets[i]
      ];

      if (currentBucketBalance > remainingValue) {
        _issuedTokensByMaturityBucket[subscriber][maturityBuckets[i]] =
          currentBucketBalance -
          remainingValue;
        remainingValue = 0;
      } else {
        _issuedTokensByMaturityBucket[subscriber][maturityBuckets[i]] = 0;
        remainingValue = remainingValue - currentBucketBalance;
      }

      i += 1;
    }

    emit Redeemed(subscriber, value, ReasonCodes.TRANSFER_SUCCESS);
  }

  function matureBalanceOf(address subscriber)
    public
    view
    returns (uint256 result)
  {
    uint256 i = 0;
    uint256[] storage maturityBuckets = _issuedTokensMaturityBuckets[
      subscriber
    ];

    while (
      i < maturityBuckets.length &&
      (maturityBuckets[i] + _maturityPeriod < _custodianContract.getTimestamp())
    ) {
      result += _issuedTokensByMaturityBucket[subscriber][maturityBuckets[i]];

      i += 1;
    }
  }

  function matureBalanceOfPending(address subscriber)
    public
    view
    returns (uint256 result)
  {
    uint256 i = 0;
    uint256[] storage maturityBuckets = _issuedTokensMaturityBuckets[
      subscriber
    ];

    while (
      i < maturityBuckets.length &&
      (maturityBuckets[maturityBuckets.length - i - 1] + _maturityPeriod >=
        _custodianContract.getTimestamp())
    ) {
      result += _issuedTokensByMaturityBucket[subscriber][
        maturityBuckets[maturityBuckets.length - i - 1]
      ];

      i += 1;
    }
  }

  function balanceOf(address account) public view override returns (uint256) {
    return super.balanceOf(account);
  }

  function redeem(address subscriber, uint256 value) public override {
    return redeem(subscriber, subscriber, owner(), value);
  }

  function redeem(
    address subscriber,
    address paymentTokenDestination,
    address tradeTokenDestination,
    uint256 value
  ) public {
    if (msg.sender != subscriber) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    bytes1 reasonCode = _custodianContract.canRedeem(
      address(this),
      subscriber,
      value
    );

    if (matureBalanceOf(subscriber) < value || balanceOf(subscriber) < value) {
      reasonCode = ReasonCodes.INSUFFICIENT_BALANCE;
    }

    if (reasonCode != ReasonCodes.TRANSFER_SUCCESS) {
      emit RedeemFailed(subscriber, value, reasonCode);
    } else {
      increaseAllowance(address(escrowManager), value);
      EscrowOrder memory escrowOrder = EscrowOrder({
        tradeToken: address(this),
        tradeTokenAmount: value,
        tradeTokenDestination: tradeTokenDestination,
        issuerAddress: owner(),
        paymentToken: _paymentTokens[0],
        paymentTokenAmount: _redemptionSwapMultiple[0] * value,
        paymentTokenDestination: paymentTokenDestination,
        investorAddress: subscriber,
        collateral: _collateral * value,
        timeout: _settlementPeriod
      });
      uint256 orderId = escrowManager.startRedemptionEscrow(escrowOrder);
      emit RedemptionEscrowInitiated(
        orderId,
        escrowOrder.tradeToken,
        escrowOrder.tradeTokenAmount,
        escrowOrder.tradeTokenDestination,
        escrowOrder.issuerAddress,
        escrowOrder.paymentToken,
        escrowOrder.paymentTokenAmount,
        escrowOrder.paymentTokenDestination,
        escrowOrder.investorAddress,
        escrowOrder.collateral,
        escrowOrder.timeout
      );
    }
  }
}
