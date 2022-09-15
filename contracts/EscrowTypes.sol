//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

struct EscrowOrder {
  address tradeToken;
  uint256 tradeTokenAmount;
  address tradeTokenDestination;
  address issuerAddress;
  address paymentToken;
  uint256 paymentTokenAmount;
  address paymentTokenDestination;
  address investorAddress;
  uint256 collateral;
  uint256 issuerCollateral;
  uint256 timeout;
}
