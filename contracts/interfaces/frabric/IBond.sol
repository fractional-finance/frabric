// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.9;

import "../frabric/IFrabric.sol";

import "../common/IComposable.sol";

interface IBond {
  event Bond(address governor, uint256 amount);
  event Unbond(address governor, uint256 amount);
  event Slash(address governor, uint256 amount);

  function usd() external view returns (address);
  function token() external view returns (address);

  function bond(uint256 amount) external;
  function unbond(address bonder, uint256 amount) external;
  function slash(address bonder, uint256 amount) external;
}

interface IBondSum is IComposableSum, IBond {}

error BondTransfer();
error NotActiveGovernor(address governor, IFrabric.GovernorStatus status);
