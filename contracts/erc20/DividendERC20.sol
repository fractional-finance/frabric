// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable as SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import "../common/Composable.sol";

import "../interfaces/erc20/IDividendERC20.sol";

// ERC20 Votes expanded with dividend functionality
abstract contract DividendERC20 is ERC20VotesUpgradeable, Composable, IDividendERC20 {
  using SafeERC20 for IERC20;

  struct Distribution {
    address token;
    uint64 block;
    uint256 amount;
  }
  // This could be an array yet gas testing on an isolate contract showed writing
  // new structs was roughly 200 gas more expensive while reading to memory was
  // roughly 2000 gas cheaper
  // This was including the monotonic uint256 increment
  uint256 private _nextID;
  mapping(uint256 => Distribution) private _distributions;
  mapping(address => mapping(uint256 => bool)) public override claimedDistribution;

  uint256[100] private __gap;

  function __DividendERC20_init(string memory name, string memory symbol) internal {
    __ERC20_init(name, symbol);
    __ERC20Permit_init(name);
    __ERC20Votes_init();

    supportsInterface[type(IERC20).interfaceId] = true;
    supportsInterface[type(IERC20PermitUpgradeable).interfaceId] = true;
    supportsInterface[type(IVotesUpgradeable).interfaceId] = true;
    supportsInterface[type(IDividendERC20).interfaceId] = true;

    _nextID = 0;
  }

  // Disable delegation to enable dividends
  // Removes the need to track both historical balances AND historical voting power
  // Also resolves legal liability which is currently not fully explored and may be a concern
  function delegate(address) public pure override(IVotesUpgradeable, ERC20VotesUpgradeable) {
    revert Delegation();
  }
  function delegateBySig(
    address, uint256, uint256, uint8, bytes32, bytes32
  ) public pure override(IVotesUpgradeable, ERC20VotesUpgradeable) {
    revert Delegation();
  }

  // Dividend implementation
  function _distribute(address from, address token, uint256 amount) internal {
    if (amount == 0) {
      revert ZeroAmount();
    }
    if (from != address(this)) {
      IERC20(token).safeTransferFrom(from, address(this), amount);
    }
    _distributions[_nextID] = Distribution(token, uint64(block.number), amount);
    _nextID++;
    emit Distributed(_nextID, token, amount);
  }

  function distribute(address token, uint256 amount) external override {
    _distribute(msg.sender, token, amount);
  }

  function claim(address person, uint256 id) external override {
    if (claimedDistribution[person][id]) {
      revert AlreadyClaimed(id);
    }
    claimedDistribution[person][id] = true;

    Distribution storage distribution = _distributions[id];
    uint256 amount = distribution.amount * getPastVotes(person, distribution.block) / getPastTotalSupply(distribution.block);
    // Also verifies this is an actual distribution and not an unset ID
    if (amount == 0) {
      revert ZeroAmount();
    }
    IERC20(distribution.token).safeTransfer(person, amount);
    emit Claimed(id, person, amount);
  }
}
