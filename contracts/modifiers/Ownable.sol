// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.4;

import "../interfaces/modifiers/IOwnable.sol";

abstract contract Ownable is IOwnable {
    address private _owner;

    constructor() {
      _owner = msg.sender;
      emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view override returns (address) {
      return _owner;
    }

    modifier onlyOwner() {
      require(owner() == msg.sender);
      _;
    }

    function renounceOwnership() public override onlyOwner {
      _owner = address(0);
        emit OwnershipTransferred(_owner, address(0));
    }

    function transferOwnership(address newOwner) public override onlyOwner {
      require(newOwner != address(0));
      _owner = newOwner;
      emit OwnershipTransferred(_owner, newOwner);
    }
}
