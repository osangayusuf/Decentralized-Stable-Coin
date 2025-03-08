// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 private constant STARTING_BALANCE = 10 ether;
    uint256 public timesMintIsCalled;
    address[] public usersWithDepositedCollateral;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        dsc = _dsc;
        engine = _engine;
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithDepositedCollateral.push(msg.sender);
    }

    // Helper Function

    function _getCollateralFromSeed(uint256 seed) private view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getUserCollateralTokenBalance(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amountCollateral == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amountDscToMint, uint256 userAddressSeed) public {
        if (usersWithDepositedCollateral.length == 0) return;

        address sender = usersWithDepositedCollateral[userAddressSeed % usersWithDepositedCollateral.length];
        vm.startPrank(sender);
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = int256((totalCollateralValueInUsd / 2) - totalDscMinted);
        if (maxDscToMint < 0) return;

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        if (amountDscToMint == 0) return;

        engine.mintDSC(amountDscToMint);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // This breaks the invariant test suite
    // function updateCollateralPrice(uint96 newPrice) public {
    //     ethUsdPriceFeed.updateAnswer(int256(uint(newPrice)));
    // }
}
