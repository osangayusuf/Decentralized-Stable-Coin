// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDecentralizedStableCoin} from "script/DeployDecentralizedStableCoin.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

using OracleLib for AggregatorV3Interface;

contract DSCEngineTest is Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    DeployDecentralizedStableCoin deployer;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address USER;
    address LIQUIDATOR;
    uint256 public constant STARTING_BALANCE = 10 ether;
    uint256 public constant DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant MINT_AMOUNT = 200 ether;
    uint256 public constant BURN_AMOUNT = 100 ether;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private ethPrice;

    function setUp() public {
        deployer = new DeployDecentralizedStableCoin();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        USER = makeAddr("USER");
        LIQUIDATOR = makeAddr("LIQUIDATOR");
        if (block.chainid == 11_155_111) {
            vm.deal(USER, STARTING_BALANCE);
            vm.deal(LIQUIDATOR, STARTING_BALANCE);
        } else {
            ERC20Mock(weth).mint(USER, STARTING_BALANCE);
            ERC20Mock(weth).mint(LIQUIDATOR, STARTING_BALANCE);
        }
        (, int256 price,,,) = AggregatorV3Interface(ethUsdPriceFeed).staleCheckLatestRoundData();
        ethPrice = uint256(price);
    }

    //////////////////////////
    // Constructor Testing ///
    //////////////////////////
    function testDscAddressIsSetCorrectly() public view {
        assertEq(address(dsc), engine.getDscAddress());
    }

    address[] tokens;
    address[] priceFeeds;

    function testRevertIfTokenAndPriceFeedAddressArraysAreNotEqual() public {
        tokens.push(weth);
        priceFeeds.push(ethUsdPriceFeed);
        priceFeeds.push(btcUsdPriceFeed);

        vm.expectPartialRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressArrayMustBeSameLength.selector);
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    function testEngineIsOwnerOfDSC() public view {
        assertEq(dsc.owner(), address(engine));
    }

    ////////////////////////////////
    // Deposit Collateral Testing //
    ////////////////////////////////
    function testRevertIfAmountIsZero() public {
        uint256 amount = 0;

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        engine.depositCollateral(weth, amount);
    }

    function testRevertIfTokenAddressIsZeroAddress() public {
        address zeroAddress;

        vm.expectRevert(DSCEngine.DSCEngine__NotZeroAddress.selector);
        engine.depositCollateral(zeroAddress, DEPOSIT_AMOUNT);
    }

    function testRevertIfTokenAddressIsInvalid() public {
        ERC20Mock invalidToken = new ERC20Mock("Random", "RAN", USER, STARTING_BALANCE);

        vm.startPrank(USER);
        vm.expectPartialRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(invalidToken), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testUserCanDepositCollateral() public {
        uint256 expectedBalance = DEPOSIT_AMOUNT * 2000;

        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 balance = engine.getAccountCollateralValue(USER);
        assertEq(balance, expectedBalance);
    }

    function testEmitCollateralDepositedEvent() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);

        vm.expectEmit();
        emit DSCEngine.CollateralDeposited(USER, weth, DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testUserCanDepositCollateralAndGetAccountInfo() public userHasDepositedAndMinted {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, DEPOSIT_AMOUNT);

        assertEq(totalDscMinted, MINT_AMOUNT);
        assertEq(totalCollateralValueInUsd, expectedCollateralValue);
    }

    modifier userHasDepositedAndMinted() {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);
        engine.mintDSC(MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    //////////////////////
    // Mint DSC Testing //
    //////////////////////
    function testUserCanMintDSC() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        engine.mintDSC(MINT_AMOUNT);

        uint256 userDSCBalance = dsc.balanceOf(USER);
        assertEq(userDSCBalance, MINT_AMOUNT);
        vm.stopPrank();
    }

    function testRevertIfMintingDSCWithoutEnoughCollateral() public {
        vm.expectPartialRevert(DSCEngine.DSCEngine__HealthFactorIsTooLow.selector);
        vm.prank(USER);
        engine.mintDSC(MINT_AMOUNT);
    }

    ////////////////////////
    // Burn DSC Testing   //
    ////////////////////////
    function testUserCanBurnDSC() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        engine.mintDSC(MINT_AMOUNT);

        dsc.approve(address(engine), BURN_AMOUNT);
        engine.burnDSC(BURN_AMOUNT);

        uint256 userDSCBalance = dsc.balanceOf(USER);
        assertEq(userDSCBalance, MINT_AMOUNT - BURN_AMOUNT);
        vm.stopPrank();
    }

    ///////////////////////////////
    // Redeem Collateral Testing //
    ///////////////////////////////
    function testUserCanRedeemCollateral() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);
        engine.mintDSC(MINT_AMOUNT);

        uint256 amountToRedeem = DEPOSIT_AMOUNT / 2;
        engine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();

        uint256 userCollateralBalance = engine.getUserCollateralTokenBalance(USER, weth);
        assertEq(userCollateralBalance, DEPOSIT_AMOUNT - amountToRedeem);
    }

    function testRevertIfRedeemingMoreCollateralThanDeposited() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        uint256 amountToRedeem = DEPOSIT_AMOUNT * 2;
        vm.expectRevert();
        engine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    ////////////////////////
    // Price Feed Testing //
    ////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsdValue = (ethPrice * ethAmount * ADDITIONAL_FEED_PRECISION) / PRICE_PRECISION;
        uint256 ethUsdPrice = engine.getUsdValue(weth, ethAmount);
        assertEq(ethUsdPrice, expectedUsdValue);
        // 32130570765000000000000
        // 3213057076500000000000000000000
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 1000 ether;
        uint256 expectedWeth = (usdAmount * PRICE_PRECISION) / (ethPrice * ADDITIONAL_FEED_PRECISION);
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ///////////////////////////
    // Liquidation Testing   //
    ///////////////////////////
    function testUserCanBeLiquidated() public liquidatorIsFunded {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        engine.mintDSC(MINT_AMOUNT * 3);

        // Simulate a price drop to make the user undercollateralized
        // vm.mockCall(
        //     ethUsdPriceFeed,
        //     abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
        //     abi.encode(0, 1000 * 1e8, 0, 0, 0) // Price drops to $1000
        // );
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000 * 1e8);

        vm.stopPrank();

        uint256 debtToCover = MINT_AMOUNT * 2;
        uint256 debtToCoverInEth = engine.getTokenAmountFromUsd(weth, debtToCover);
        uint256 bonusCollateral = (debtToCoverInEth * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 expectedLiquidatorBalance = STARTING_BALANCE - DEPOSIT_AMOUNT + debtToCoverInEth + bonusCollateral;

        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), MINT_AMOUNT * 2);
        engine.liquidate(USER, weth, debtToCover);
        vm.stopPrank();

        uint256 liquidatorCollateralBalance = IERC20(weth).balanceOf(LIQUIDATOR);
        assertEq(liquidatorCollateralBalance, expectedLiquidatorBalance);
    }

    function testRevertIfLiquidatingUserWithOkayHealthFactor() public {
        vm.startPrank(USER);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        engine.mintDSC(MINT_AMOUNT);
        vm.stopPrank();

        vm.expectPartialRevert(DSCEngine.DSCEngine__HealthFactorIsOkay.selector);
        vm.prank(LIQUIDATOR);
        engine.liquidate(USER, weth, MINT_AMOUNT);
    }

    modifier liquidatorIsFunded() {
        vm.startPrank(LIQUIDATOR);
        IERC20(weth).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(weth, DEPOSIT_AMOUNT);

        engine.mintDSC(MINT_AMOUNT * 2);
        vm.stopPrank();
        _;
    }
}
