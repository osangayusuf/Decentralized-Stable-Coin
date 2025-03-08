// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.28;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Osanga Yusuf
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine. This contract is just th ERC20 implementation of the stablecoin system
 * @dev A decentralized stable coin that is pegged to the US Dollar.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor(address owner) ERC20("DecentralizedStableCoin", "DSC") Ownable(owner) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        require(_amount > 0, DecentralizedStableCoin__MustBeMoreThanZero());
        require(balance >= _amount, DecentralizedStableCoin__BurnAmountExceedsBalance());
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        require(_to != address(0), DecentralizedStableCoin__NotZeroAddress());
        require(_amount > 0, DecentralizedStableCoin__MustBeMoreThanZero());
        _mint(_to, _amount);
        return true;
    }
}
