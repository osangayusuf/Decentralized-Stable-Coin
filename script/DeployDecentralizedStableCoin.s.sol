// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDecentralizedStableCoin is Script {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        helperConfig = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // Derive the deployer address from the private key
        address deployerAddress = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        dsc = new DecentralizedStableCoin(deployerAddress);
        engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (dsc, engine, helperConfig);
    }
}
