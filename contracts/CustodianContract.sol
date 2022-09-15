//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./ReasonCodes.sol";
import "./TokenTvTTypes.sol";
import "./TimeOracle.sol";
import "./interfaces/ICustodianContractQuery.sol";
import "./TokenCreatorTvT.sol";

contract CustodianContract is
  Initializable,
  OwnableUpgradeable,
  ICustodianContractQuery,
  ReasonCodes
{
  string public constant VERSION = "0.0.1";

  TokenCreatorTvT public tokenCreatorTvT;
  TimeOracle public timeOracle;

  // Initalize Method For Upgradable Contracts
  function initialize(address tokenCreatorTvTAddr, address timeOracleAddr)
    public
    initializer
  {
    tokenCreatorTvT = TokenCreatorTvT(tokenCreatorTvTAddr);
    timeOracle = TimeOracle(timeOracleAddr);
    __Ownable_init();
  }

  struct RoleData {
    address primaryAddress;
    string countryCode;
    address[] addresses;
  }

  struct LiquidityPool {
    address primaryAddress;
    address settlementAddress;
  }

  enum TokenStatus {
    NonExistent,
    Published
  }

  enum PaymentTokenStatus {
    Inactive,
    Active
  }

  struct TokenData {
    string name;
    string symbol;
    uint256 value;
    string currency;
    address issuerPrimaryAddress;
    bool earlyRedemption;
    uint256 minSubscription;
    TokenStatus status;
    TokenType tokenType;
    address address_;
    bool onChainKyc;
  }

  struct KycBasicDetails {
    bool leiCheck;
    bool bankCheck;
    bool citizenshipCheck;
    bool addressCheck;
  }

  struct KycAMLCTF {
    bool pepCheck;
    bool sanctionScreening;
    bool suspiciousActivityReport;
    bool cddReport;
    bool fatfComplianceCheck;
  }

  struct KycData {
    bytes32 countryCode;
    bool kycStatus;
    bool accredation;
    bool affiliation;
    bool exempted;
    KycBasicDetails kycBasicDetails;
    KycAMLCTF kycAmlCtf;
  }

  struct InvestorClassificationRules {
    bool isExempted;
    bool isAccredited;
    bool isAffiliated;
  }
  struct TokenRestrictions {
    bytes32[] allowedCountries;
    InvestorClassificationRules allowedInvestorClassifications;
    bool useIssuerWhitelist;
  }

  mapping(address => mapping(address => KycData)) public kycVerifications;
  mapping(address => RoleData) public _issuers;
  mapping(address => LiquidityPool) public _liquidityPool;

  mapping(address => address) public _addressToIssuerPrimaryAddress;

  mapping(address => bool) internal _isIssuer;

  mapping(address => TokenData) internal _tokens;
  mapping(address => TokenRestrictions) internal _tokenRestrictions;
  mapping(address => address[]) internal _tokenAddressesByIssuerPrimaryAddress;

  mapping(string => bool) internal _tokenWithNameExists;
  mapping(string => bool) internal _tokenWithSymbolExists;

  mapping(address => mapping(address => bool)) internal _whitelist;
  mapping(address => mapping(address => bool)) internal _issuerWhitelist;
  mapping(address => string) internal allowedCountries;
  mapping(address => string[]) internal allowedClassifications;
  mapping(address => bool) internal useIssuerWhitelist;

  mapping(address => PaymentTokenStatus) internal _paymentTokensStatus;

  event TokenPublished(string symbol, address address_);
  event AddWhitelist(address tokenAddress, address address_);
  event RemoveWhitelist(address tokenAddress, address address_);
  event AddIssuerWhitelist(address issuerAddress, address address_);
  event RemoveIssuerWhitelist(address issuerAddress, address address_);

  event AddIssuer(address PrimaryAddress);
  event RemoveIssuer(address primaryAddress);
  event AddIssuerAddress(address primaryAddress, address[] addresses);
  event RemoveIssuerAddress(address primaryAddress, address[] addresses);

  event PaymentTokenAdded(address tokenAddress);

  event KycUpdated(address tokenAddress, address investorAddress);

  event AddLiquidityPool(address primaryAddress, address settlementAddress);
  event RemoveLiquidityPool(address primaryAddress);

  // Document Events
  event DocumentRemoved(
    bytes32 indexed _name,
    string _uri,
    bytes32 _documentHash
  );
  event DocumentUpdated(
    bytes32 indexed _name,
    string _uri,
    bytes32 _documentHash
  );

  // Errors
  error ERC1066Error(bytes1 errorCode, string message);

  enum ErrorCondition {
    WRONG_CALLER,
    USER_ALREADY_EXISTS,
    USER_DOES_NOT_EXIST,
    REMOVED_ISSUER_HAS_TOKENS,
    REMOVED_CUSTODIAN_HAS_TOKENS,
    REMOVED_KYCPROVIDER_HAS_TOKENS,
    TOKEN_WRONG_ISSUER,
    TOKEN_WRONG_CUSTODIAN,
    TOKEN_WRONG_KYCPROVIDER,
    TOKEN_WRONG_INSURER,
    TOKEN_SAME_NAME_EXISTS,
    TOKEN_SAME_SYMBOL_EXISTS,
    TOKEN_WRONG_PAYMENT_TOKEN,
    TOKEN_EARLY_REDEMPTION_NOT_ALLOWED,
    TOKEN_DOES_NOT_EXIST,
    TOKEN_PAUSED,
    WRONG_INPUT,
    REMOVED_INSURER_HAS_TOKENS,
    LIQUIDITY_POOL_EXISTS,
    LIQUIDITY_POOL_DOES_NOT_EXIST
  }

  function getTimestamp() external view override returns (uint256) {
    return timeOracle.getTimestamp();
  }

  function throwError(ErrorCondition condition) internal pure {
    if (condition == ErrorCondition.WRONG_CALLER) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "caller is not allowed"
      );
    } else if (condition == ErrorCondition.USER_ALREADY_EXISTS) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "user already exists"
      );
    } else if (condition == ErrorCondition.USER_DOES_NOT_EXIST) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "user does not exist"
      );
    } else if (condition == ErrorCondition.REMOVED_ISSUER_HAS_TOKENS) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "removed issuer must not have tokens"
      );
    } else if (condition == ErrorCondition.TOKEN_WRONG_ISSUER) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "issuer does not exists"
      );
    } else if (condition == ErrorCondition.TOKEN_SAME_NAME_EXISTS) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "token with the same name already exists"
      );
    } else if (condition == ErrorCondition.TOKEN_SAME_SYMBOL_EXISTS) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "token with the same symbol already exists"
      );
    } else if (condition == ErrorCondition.TOKEN_WRONG_PAYMENT_TOKEN) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "payment token is not active"
      );
    } else if (condition == ErrorCondition.TOKEN_EARLY_REDEMPTION_NOT_ALLOWED) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "early redemption is not allowed for TvT tokens"
      );
    } else if (condition == ErrorCondition.WRONG_INPUT) {
      revert ERC1066Error(ReasonCodes.APP_SPECIFIC_FAILURE, "wrong input");
    } else if (condition == ErrorCondition.TOKEN_DOES_NOT_EXIST) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "token does not exist"
      );
    } else if (condition == ErrorCondition.TOKEN_PAUSED) {
      revert ERC1066Error(ReasonCodes.APP_SPECIFIC_FAILURE, "token is paused");
    } else if (condition == ErrorCondition.LIQUIDITY_POOL_EXISTS) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "liquidity pool already exists"
      );
    } else if (condition == ErrorCondition.LIQUIDITY_POOL_DOES_NOT_EXIST) {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "liquidity pool does not exist"
      );
    } else {
      revert ERC1066Error(
        ReasonCodes.APP_SPECIFIC_FAILURE,
        "unknown error condition"
      );
    }
  }

  function updateKyc(
    address issuerAddress,
    address investorAddress,
    KycData calldata investorKycData
  ) external onlyIssuer {
    kycVerifications[issuerAddress][investorAddress] = investorKycData;
    emit KycUpdated(issuerAddress, investorAddress);
  }

  function isIssuer(address addr) public view returns (bool) {
    return _isIssuer[_addressToIssuerPrimaryAddress[addr]];
  }

  function isIssuerOwnerOrEmployee(address primaryIssuer, address issuer)
    public
    view
    override
    returns (bool)
  {
    return _addressToIssuerPrimaryAddress[issuer] == primaryIssuer;
  }

  function isWhitelisted(address tokenAddress, address investorAddress)
    public
    view
    returns (bool)
  {
    return _whitelist[tokenAddress][investorAddress];
  }

  function isIssuerWhitelisted(address issuerAddress, address investorAddress)
    public
    view
    returns (bool)
  {
    return _issuerWhitelist[issuerAddress][investorAddress];
  }

  modifier onlyIssuer() {
    if (isIssuer(msg.sender) == false) {
      throwError(ErrorCondition.WRONG_CALLER);
    }
    _;
  }

  function _addRole(
    mapping(address => bool) storage _isUserType,
    mapping(address => RoleData) storage _usersData,
    mapping(address => address) storage _addressToUserPrimaryAddress,
    string calldata countryCode,
    address primaryAddress
  ) internal {
    if (_isUserType[primaryAddress] == true) {
      throwError(ErrorCondition.USER_ALREADY_EXISTS);
    }

    _isUserType[primaryAddress] = true;
    _usersData[primaryAddress].countryCode = countryCode;
    _usersData[primaryAddress].primaryAddress = primaryAddress;
    _usersData[primaryAddress].addresses.push(primaryAddress);
    _addressToUserPrimaryAddress[primaryAddress] = primaryAddress;
  }

  function _removeRole(
    mapping(address => bool) storage _isUserType,
    mapping(address => RoleData) storage _usersData,
    mapping(address => address) storage _addressToUserPrimaryAddress,
    address primaryAddress
  ) internal {
    if (_isUserType[primaryAddress] == false) {
      throwError(ErrorCondition.USER_DOES_NOT_EXIST);
    }

    address[] storage addresses = _usersData[primaryAddress].addresses;

    for (uint256 i = 0; i < addresses.length; i++) {
      delete _addressToUserPrimaryAddress[addresses[i]];
    }

    delete _isUserType[primaryAddress];
    delete _usersData[primaryAddress];
  }

  function _addRoleAddresses(
    mapping(address => bool) storage _isUserType,
    mapping(address => RoleData) storage _usersData,
    mapping(address => address) storage _addressToUserPrimaryAddress,
    address primaryAddress,
    address[] calldata addresses
  ) internal {
    bool senderNotOwner = owner() != msg.sender;
    bool senderNoPrimaryArgMatch = primaryAddress != msg.sender;
    bool primaryArgNotUser = _isUserType[primaryAddress] == false;

    if (senderNotOwner && (senderNoPrimaryArgMatch || primaryArgNotUser)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    if (primaryArgNotUser) {
      throwError(ErrorCondition.USER_DOES_NOT_EXIST);
    }

    address[] storage userAddresses = _usersData[primaryAddress].addresses;

    for (uint256 i = 0; i < addresses.length; i++) {
      _addressToUserPrimaryAddress[addresses[i]] = primaryAddress;
      userAddresses.push(addresses[i]);
    }
  }

  function _removeRoleAddresses(
    mapping(address => bool) storage _isUserType,
    mapping(address => RoleData) storage _usersData,
    mapping(address => address) storage _addressToUserPrimaryAddress,
    address primaryAddress,
    address[] calldata addresses
  ) internal {
    bool senderNotOwner = owner() != msg.sender;
    bool senderNoPrimaryArgMatch = primaryAddress != msg.sender;
    bool primaryArgNotUser = _isUserType[primaryAddress] == false;

    if (senderNotOwner && (senderNoPrimaryArgMatch || primaryArgNotUser)) {
      throwError(ErrorCondition.WRONG_CALLER);
    }

    if (primaryArgNotUser) {
      throwError(ErrorCondition.USER_DOES_NOT_EXIST);
    }

    address[] storage userAddresses = _usersData[primaryAddress].addresses;

    for (uint256 i = 0; i < addresses.length; i++) {
      for (uint256 j = 0; j < userAddresses.length; j++) {
        if (userAddresses[j] == addresses[i]) {
          delete _addressToUserPrimaryAddress[userAddresses[j]];
          delete userAddresses[j];
        }
      }
    }
  }

  function addIssuer(string calldata countryCode, address primaryAddress)
    external
    onlyOwner
  {
    _addRole(
      _isIssuer,
      _issuers,
      _addressToIssuerPrimaryAddress,
      countryCode,
      primaryAddress
    );
    emit AddIssuer(primaryAddress);
  }

  function removeIssuer(address primaryAddress) external onlyOwner {
    if (_tokenAddressesByIssuerPrimaryAddress[primaryAddress].length > 0) {
      throwError(ErrorCondition.REMOVED_ISSUER_HAS_TOKENS);
    }
    _removeRole(
      _isIssuer,
      _issuers,
      _addressToIssuerPrimaryAddress,
      primaryAddress
    );
    emit RemoveIssuer(primaryAddress);
  }

  function addIssuerAccounts(
    address primaryAddress,
    address[] calldata addresses
  ) external {
    _addRoleAddresses(
      _isIssuer,
      _issuers,
      _addressToIssuerPrimaryAddress,
      primaryAddress,
      addresses
    );
    emit AddIssuerAddress(primaryAddress, addresses);
  }

  function removeIssuerAccounts(
    address primaryAddress,
    address[] calldata addresses
  ) external {
    _removeRoleAddresses(
      _isIssuer,
      _issuers,
      _addressToIssuerPrimaryAddress,
      primaryAddress,
      addresses
    );
    emit RemoveIssuerAddress(primaryAddress, addresses);
  }

  function addLiqudityPool(address primaryAddress, address settlementAddress)
    external
    onlyOwner
  {
    if (_liquidityPool[primaryAddress].primaryAddress != address(0)) {
      throwError(ErrorCondition.LIQUIDITY_POOL_EXISTS);
    }
    _liquidityPool[primaryAddress].primaryAddress = primaryAddress;
    _liquidityPool[primaryAddress].settlementAddress = settlementAddress;
    emit AddLiquidityPool(primaryAddress, settlementAddress);
  }

  function removeLiquidityPool(address primaryAddress) external {
    if (_liquidityPool[primaryAddress].primaryAddress == address(0)) {
      throwError(ErrorCondition.LIQUIDITY_POOL_DOES_NOT_EXIST);
    }
    delete _liquidityPool[primaryAddress];
    emit RemoveLiquidityPool(primaryAddress);
  }

  struct TokenInput {
    string name;
    string symbol;
    uint256 maxTotalSupply;
    uint256 value;
    string currency;
    address issuerPrimaryAddress;
    bool earlyRedemption;
    uint256 minSubscription;
    address[] paymentTokens;
    uint256[] issuanceSwapMultiple;
    uint256[] redemptionSwapMultiple;
    uint256 maturityPeriod;
    uint256 settlementPeriod;
    uint256 collateral;
    bytes32[] countries;
    InvestorClassificationRules investorClassifications;
    bool useIssuerWhitelist;
    bool onChainKyc;
    bytes32 documentName;
    string documentUri;
    bytes32 documentHash;
    TokenType tokenType;
    address liquidityPool;
    address issuerSettlementAddress;
    IssueType issueType;
  }

  function publishToken(TokenInput calldata token) external onlyIssuer {
    if (_isIssuer[token.issuerPrimaryAddress] == false) {
      throwError(ErrorCondition.TOKEN_WRONG_ISSUER);
    }

    if (_tokenWithNameExists[token.name] == true) {
      throwError(ErrorCondition.TOKEN_SAME_NAME_EXISTS);
    }

    if (_tokenWithSymbolExists[token.symbol] == true) {
      throwError(ErrorCondition.TOKEN_SAME_SYMBOL_EXISTS);
    }

    if (
      token.paymentTokens.length != token.issuanceSwapMultiple.length ||
      token.paymentTokens.length != token.redemptionSwapMultiple.length
    ) {
      throwError(ErrorCondition.WRONG_INPUT);
    }

    if (token.paymentTokens.length > 0 && token.earlyRedemption) {
      throwError(ErrorCondition.TOKEN_EARLY_REDEMPTION_NOT_ALLOWED);
    }
    if (token.paymentTokens.length < 0) {
      throwError(ErrorCondition.WRONG_INPUT);
    }

    for (uint256 i = 0; i < token.paymentTokens.length; i += 1) {
      if (
        _paymentTokensStatus[token.paymentTokens[i]] !=
        PaymentTokenStatus.Active
      ) {
        throwError(ErrorCondition.TOKEN_WRONG_PAYMENT_TOKEN);
      }
    }

    address tokenAddress = tokenCreatorTvT.publishToken(
      TokenTvTInput({
        name: token.name,
        symbol: token.symbol,
        maxTotalSupply: token.maxTotalSupply,
        paymentTokens: token.paymentTokens,
        issuanceSwapMultiple: token.issuanceSwapMultiple,
        redemptionSwapMultiple: token.redemptionSwapMultiple,
        maturityPeriod: token.maturityPeriod,
        settlementPeriod: token.settlementPeriod,
        collateral: token.collateral,
        issuerCollateralShare: token.collateral,
        documentName: token.documentName,
        documentUri: token.documentUri,
        documentHash: token.documentHash,
        tokenType: token.tokenType,
        issuerSettlementAddress: token.issuerSettlementAddress,
        issueType: token.issueType
      }),
      msg.sender
    );

    _tokens[tokenAddress].name = token.name;
    _tokens[tokenAddress].symbol = token.symbol;
    _tokens[tokenAddress].value = token.value;
    _tokens[tokenAddress].currency = token.currency;
    _tokens[tokenAddress].issuerPrimaryAddress = token.issuerPrimaryAddress;
    _tokens[tokenAddress].earlyRedemption = token.earlyRedemption;
    _tokens[tokenAddress].minSubscription = token.minSubscription;
    _tokens[tokenAddress].status = TokenStatus.Published;
    _tokens[tokenAddress].address_ = tokenAddress;
    _tokens[tokenAddress].onChainKyc = token.onChainKyc;
    _tokens[tokenAddress].tokenType = token.tokenType;
    _tokenWithNameExists[token.name] = true;
    _tokenWithSymbolExists[token.symbol] = true;
    _tokenAddressesByIssuerPrimaryAddress[token.issuerPrimaryAddress].push(
      tokenAddress
    );
    _tokenRestrictions[tokenAddress].allowedCountries = token.countries;
    _tokenRestrictions[tokenAddress].allowedInvestorClassifications = token
      .investorClassifications;
    _tokenRestrictions[tokenAddress].useIssuerWhitelist = token
      .useIssuerWhitelist;

    emit TokenPublished(token.symbol, tokenAddress);
  }

  function getTokens(address issuerPrimaryAddress)
    external
    view
    returns (TokenData[] memory result)
  {
    result = new TokenData[](
      _tokenAddressesByIssuerPrimaryAddress[issuerPrimaryAddress].length
    );

    for (
      uint256 i = 0;
      i < _tokenAddressesByIssuerPrimaryAddress[issuerPrimaryAddress].length;
      i++
    ) {
      result[i] = _tokens[
        _tokenAddressesByIssuerPrimaryAddress[issuerPrimaryAddress][i]
      ];
    }
  }

  function assertTokenExists(address tokenAddress) internal view {
    if (_tokens[tokenAddress].address_ == address(0x0)) {
      throwError(ErrorCondition.TOKEN_DOES_NOT_EXIST);
    }
  }

  function assertTokenNotPaused(address tokenAddress) internal view {
    bool isPaused = Pausable(tokenAddress).paused();

    if (isPaused) {
      throwError(ErrorCondition.TOKEN_PAUSED);
    }
  }

  function addWhitelist(address tokenAddress, address[] calldata addresses)
    external
    onlyIssuer
  {
    assertTokenExists(tokenAddress);
    assertTokenNotPaused(tokenAddress);

    for (uint256 i = 0; i < addresses.length; i++) {
      _whitelist[tokenAddress][addresses[i]] = true;
      emit AddWhitelist(tokenAddress, addresses[i]);
    }
  }

  function removeWhitelist(address tokenAddress, address[] calldata addresses)
    external
    onlyIssuer
  {
    assertTokenExists(tokenAddress);
    assertTokenNotPaused(tokenAddress);

    for (uint256 i = 0; i < addresses.length; i++) {
      delete _whitelist[tokenAddress][addresses[i]];
      emit RemoveWhitelist(tokenAddress, addresses[i]);
    }
  }

  function addIssuerWhitelist(
    address issuerAddress,
    address[] calldata addresses
  ) external onlyIssuer {
    for (uint256 i = 0; i < addresses.length; i++) {
      _issuerWhitelist[issuerAddress][addresses[i]] = true;
      emit AddIssuerWhitelist(issuerAddress, addresses[i]);
    }
  }

  function removeIssuerWhitelist(
    address issuerAddress,
    address[] calldata addresses
  ) external onlyIssuer {
    for (uint256 i = 0; i < addresses.length; i++) {
      delete _issuerWhitelist[issuerAddress][addresses[i]];
      emit RemoveIssuerWhitelist(issuerAddress, addresses[i]);
    }
  }

  function addPaymentToken(address tokenAddress) external onlyOwner {
    _paymentTokensStatus[tokenAddress] = PaymentTokenStatus.Active;
    emit PaymentTokenAdded(tokenAddress);
  }

  function removePaymentToken(address tokenAddress) external onlyOwner {
    delete _paymentTokensStatus[tokenAddress];
  }

  function canIssue(
    address tokenAddress,
    address investor,
    uint256 value
  ) external view override returns (bytes1) {
    assertTokenExists(tokenAddress);
    assertTokenNotPaused(tokenAddress);
    if (_tokens[tokenAddress].tokenType == TokenType.Subscription) {
      address tokenIssuer = _tokens[tokenAddress].issuerPrimaryAddress;

      // Check if KYC is Complete.
      if (
        !kycVerifications[tokenIssuer][investor].kycStatus &&
        _tokens[tokenAddress].onChainKyc
      ) {
        return ReasonCodes.KYC_INCOMPLETE;
      }

      // Check if investorCountry is allowed using token restrictions.
      bool isInvestorCountryAllowed = false;
      for (
        uint256 i = 0;
        i < _tokenRestrictions[tokenAddress].allowedCountries.length;
        i++
      ) {
        if (
          _tokenRestrictions[tokenAddress].allowedCountries[i] ==
          kycVerifications[tokenIssuer][investor].countryCode
        ) {
          isInvestorCountryAllowed = true;
          break;
        }
      }
      if (
        !isInvestorCountryAllowed &&
        _tokenRestrictions[tokenAddress].allowedCountries.length > 0 &&
        kycVerifications[tokenIssuer][investor].kycBasicDetails.citizenshipCheck
      ) {
        return ReasonCodes.COUNTRY_NOT_ALLOWED;
      }

      // Check if investorClassification is allowed using token restrictions.
      if (
        _tokenRestrictions[tokenAddress]
          .allowedInvestorClassifications
          .isExempted
      ) {
        if (!kycVerifications[tokenIssuer][investor].exempted) {
          return ReasonCodes.INVESTOR_CLASSIFICATION_NOT_ALLOWED;
        }
      }
      if (
        _tokenRestrictions[tokenAddress]
          .allowedInvestorClassifications
          .isAccredited
      ) {
        if (!kycVerifications[tokenIssuer][investor].accredation) {
          return ReasonCodes.INVESTOR_CLASSIFICATION_NOT_ALLOWED;
        }
      }
      if (
        _tokenRestrictions[tokenAddress]
          .allowedInvestorClassifications
          .isAffiliated
      ) {
        if (!kycVerifications[tokenIssuer][investor].affiliation) {
          return ReasonCodes.INVESTOR_CLASSIFICATION_NOT_ALLOWED;
        }
      }

      if (_tokenRestrictions[tokenAddress].useIssuerWhitelist) {
        if (!_issuerWhitelist[tokenIssuer][investor]) {
          return ReasonCodes.INVALID_RECEIVER;
        }
      } else {
        if (
          (_whitelist[tokenAddress][investor] != true) &&
          (_issuerWhitelist[tokenIssuer][investor] != true)
        ) {
          return ReasonCodes.INVALID_RECEIVER;
        }
      }

      if (value == 0) {
        return ReasonCodes.APP_SPECIFIC_FAILURE;
      }
    }

    return ReasonCodes.TRANSFER_SUCCESS;
  }

  function canRedeem(
    address tokenAddress,
    address investor,
    uint256 value
  ) external view override returns (bytes1) {
    assertTokenExists(tokenAddress);
    assertTokenNotPaused(tokenAddress);
    if (_tokens[tokenAddress].tokenType == TokenType.Subscription) {
      address tokenIssuer = _tokens[tokenAddress].issuerPrimaryAddress;

      if (
        (_whitelist[tokenAddress][investor] != true) &&
        (_issuerWhitelist[tokenIssuer][investor] != true)
      ) {
        return ReasonCodes.INVALID_RECEIVER;
      }

      if (value == 0) {
        return ReasonCodes.APP_SPECIFIC_FAILURE;
      }
    }

    return ReasonCodes.TRANSFER_SUCCESS;
  }

  function tokenExists(address tokenAddress) external view returns (bool) {
    return _tokens[tokenAddress].status == TokenStatus.Published;
  }
}
