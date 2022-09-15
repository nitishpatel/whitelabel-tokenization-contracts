//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./TokenBase.sol";
import "./TokenTvTTypes.sol";
import "./interfaces/ITokenHooks.sol";
import "./interfaces/IEscrowInitiate.sol";

contract TokenTvT is TokenBase, ITokenHooks {
  string public constant VERSION = "0.0.1";
  string public constant TYPE = "TokenTvT";

  address[] public paymentTokens;
  uint256[] internal _issuanceSwapMultiple;
  uint256[] internal _redemptionSwapMultiple;
  uint256 public maturityPeriod;
  uint256 internal _settlementPeriod;
  uint256 internal _collateral;
  uint256 internal _issuerCollateral;
  uint256 internal _insurerCollateral;
  address internal _collateralProvider;

  address internal _issuerSettlementAddress;
  IssueType internal _issueType;
  struct Document {
    bytes32 docHash; // Hash of the document
    string uri; // URI of the document that exist off-chain
  }

  mapping(bytes32 => Document) internal _documents;

  mapping(address => mapping(uint256 => uint256))
    internal _issuedTokensByMaturityBucket;
  mapping(address => uint256[]) internal _issuedTokensMaturityBuckets;

  event TokenIssuanceSwapRatioUpdated(uint256 ratio);

  IEscrowInitiate public escrowManager;

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
    uint256 issuerCollateral,
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
    uint256 issuerCollateral,
    uint256 timeout
  );

  constructor(
    TokenTvTInput memory input,
    address custodianContract,
    address escrowManagerAddress
  )
    TokenBase(input.name, input.symbol, input.maxTotalSupply, custodianContract)
  {
    paymentTokens = input.paymentTokens;
    _issuanceSwapMultiple = input.issuanceSwapMultiple;
    _redemptionSwapMultiple = input.redemptionSwapMultiple;
    maturityPeriod = input.maturityPeriod;
    _settlementPeriod = input.settlementPeriod;
    _collateral = input.collateral;
    _issuerCollateral = input.issuerCollateralShare;
    _issuerSettlementAddress = input.issuerSettlementAddress;
    _issueType = input.issueType;

    escrowManager = IEscrowInitiate(escrowManagerAddress);
    _documents[input.documentName] = Document(
      input.documentHash,
      input.documentUri
    );
  }

  function burnTokens(uint256 amount) public virtual override {
    if (msg.sender != address(escrowManager)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }
    _burn(owner(), amount);
  }

  function updateTokenIssuanceSwapRatio(uint256 ratio) external onlyIssuer {
    if (ratio < 0) {
      throwError(ErrorCondition.WRONG_INPUT);
    }

    _issuanceSwapMultiple[0] = ratio;
    emit TokenIssuanceSwapRatioUpdated(ratio);
  }

  function getIssuanceSwapRatio() external view returns (uint256) {
    return _issuanceSwapMultiple[0];
  }

  function issue(address subscriber, uint256 value) public override onlyIssuer {
    return issue(subscriber, _issuerSettlementAddress, subscriber, value);
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
      if (reasonCode == ReasonCodes.KYC_INCOMPLETE) {
        throwError(ErrorCondition.KYC_INCOMPLETE);
      } else if (reasonCode == ReasonCodes.COUNTRY_NOT_ALLOWED) {
        throwError(ErrorCondition.COUNTRY_NOT_ALLOWED);
      } else if (
        reasonCode == ReasonCodes.INVESTOR_CLASSIFICATION_NOT_ALLOWED
      ) {
        throwError(ErrorCondition.INVESTOR_CLASSIFICATION_NOT_ALLOWED);
      } else {
        throwError(ErrorCondition.CUSTODIAN_VALIDATION_FAIL);
      }
    } else {
      _mint(tokenOwner, value);
      increaseAllowance(address(escrowManager), value);
      EscrowOrder memory escrowOrder = EscrowOrder({
        tradeToken: address(this),
        tradeTokenAmount: value,
        tradeTokenDestination: tradeTokenDestination,
        issuerAddress: tokenOwner,
        paymentToken: paymentTokens[0],
        paymentTokenAmount: _issuanceSwapMultiple[0] * value,
        paymentTokenDestination: paymentTokenDestination,
        investorAddress: subscriber,
        collateral: _collateral * value,
        issuerCollateral: _issuerCollateral * value,
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
        escrowOrder.issuerCollateral,
        escrowOrder.timeout
      );
    }
  }

  function onIssue(
    address subscriber,
    uint256 value,
    uint256 orderId
  ) external override {
    if (msg.sender != address(escrowManager)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    uint256 timestamp = _custodianContract.getTimestamp();

    _issuedTokensByMaturityBucket[subscriber][timestamp] += value;
    _issuedTokensMaturityBuckets[subscriber].push(timestamp);

    emit Issued(subscriber, value, ReasonCodes.TRANSFER_SUCCESS, orderId);
  }

  function onRedeem(
    address subscriber,
    uint256 value,
    uint256 orderId
  ) external override {
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
      (maturityBuckets[i] + maturityPeriod < _custodianContract.getTimestamp())
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

    emit Redeemed(
      subscriber,
      value,
      ReasonCodes.TRANSFER_SUCCESS,
      orderId,
      totalSupply()
    );
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
      (maturityBuckets[i] + maturityPeriod < _custodianContract.getTimestamp())
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
      (maturityBuckets[maturityBuckets.length - i - 1] + maturityPeriod >=
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
    uint256 redeemPrice = _redemptionSwapMultiple[0] * value;
    if (_issueType == IssueType.NAV) {
      redeemPrice = _issuanceSwapMultiple[0] * value;
    }
    if (reasonCode != ReasonCodes.TRANSFER_SUCCESS) {
      throwError(ErrorCondition.CUSTODIAN_VALIDATION_FAIL);
    } else {
      increaseAllowance(address(escrowManager), value);
      EscrowOrder memory escrowOrder = EscrowOrder({
        tradeToken: address(this),
        tradeTokenAmount: value,
        tradeTokenDestination: tradeTokenDestination,
        issuerAddress: _issuerSettlementAddress,
        paymentToken: paymentTokens[0],
        paymentTokenAmount: redeemPrice,
        paymentTokenDestination: paymentTokenDestination,
        investorAddress: subscriber,
        collateral: _collateral * value,
        issuerCollateral: _issuerCollateral * value,
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
        escrowOrder.issuerCollateral,
        escrowOrder.timeout
      );
    }
  }

  function getDocument(bytes32 _name)
    external
    view
    returns (string memory, bytes32)
  {
    return (_documents[_name].uri, _documents[_name].docHash);
  }
}
