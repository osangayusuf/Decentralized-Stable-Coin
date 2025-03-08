// SPDX-License-Identifier: MIT

// Invariants
// 1. The total supply of DSC should be less than the total collateral value
// 2. Getter view functions should never revert

pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDecentralizedStableCoin} from "script/DeployDecentralizedStableCoin.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    DeployDecentralizedStableCoin deployer;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDecentralizedStableCoin();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethBalance = IERC20(weth).balanceOf(address(engine));
        uint256 wbtcBalance = IERC20(wbtc).balanceOf(address(engine));
        uint256 wethBalanceInUsd = engine.getUsdValue(weth, wethBalance);
        uint256 wbtcBalanceInUsd = engine.getUsdValue(wbtc, wbtcBalance);
        uint256 totalCollateralValue = wethBalanceInUsd + wbtcBalanceInUsd;

        console.log("Times mint is called: ", handler.timesMintIsCalled());
        console.log("Total supply: ", totalSupply);
        console.log("Total collateral value: ", totalCollateralValue);

        assert(totalSupply <= totalCollateralValue);
    }
}
