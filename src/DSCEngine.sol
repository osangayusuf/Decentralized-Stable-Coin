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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Osanga Yusuf
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properies:
 * 1. Collateral: Exogenous (ETH & BTC)
 * 2. Minting: Algorithmic
 * 3. Relative Stability: Pegged to USD
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by wETH and WBTC
 *
 * Our DSC system should always be "overcollateralized", and the collateral should be held in a smart contract that is separate from the DSC contract. At no point sholud the value of all collateral <= the $ backed value of all DSC tokens.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and burning the stablecoin, as well as depositing and withdrawing collateral.
 * @notice this contract is VERY loosely based on the MakerDAO DSS system.
 */

using OracleLib for AggregatorV3Interface;

contract DSCEngine is ReentrancyGuard {
    ////////////////////////
    // Errors             //
    ////////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressArrayMustBeSameLength(
        uint256 tokenAddressesLength, uint256 priceFeedAddressesLength
    );
    error DSCEngine__NotZeroAddress();
    error DSCEngine__NotAllowedToken(address tokenAddress);
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsTooLow(uint256 healthFactor);
    error DSCEngine__HealthFactorIsOkay(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 healthFactor);
    error DSCEngine__MintDscFailed();
    error DSCEngine__NoMintedTokens();

    ////////////////////////
    // State Variables    //
    ////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collateralTokens;

    ////////////////////////
    // Events             //
    ////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ////////////////////////
    // Modifiers          //
    ////////////////////////
    modifier moreThanZero(uint256 amount) {
        require(amount != 0, DSCEngine__MustBeMoreThanZero());
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        require(tokenAddress != address(0), DSCEngine__NotZeroAddress());
        require(s_priceFeeds[tokenAddress] != address(0), DSCEngine__NotAllowedToken(tokenAddress));
        _;
    }

    ////////////////////////
    // Functions          //
    ////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        require(
            tokenAddresses.length == priceFeedAddresses.length,
            DSCEngine__TokenAddressAndPriceFeedAddressArrayMustBeSameLength(
                tokenAddresses.length, priceFeedAddresses.length
            )
        );

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     * @dev Deposit collateral and mint DSC tokens
     * @notice This function deposits collateral and mints DSC tokens in one transaction.
     * @param tokenCollateralAddress The address of the collateral token.
     * @param amountCollateral The amount of collateral to be deposited.
     * @param amountDscTomint The amount of DSC to mint.
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscTomint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscTomint);
    }

    /**
     * @dev Deposit collateral into the system
     * @notice Follows CEI(Checks, Effects, Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        payable
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        require(success, DSCEngine__TransferFailed());
    }

    /**
     * @dev Withdraw collateral from the system
     * @param tokenCollateralAddress The address of the token to withdraw as collateral
     * @param amountCollateral The amount of the token to withdraw as collateral
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev Burn DSC tokens and withdraw collateral
     * @notice This function burns DSC tokens and withdraws collateral in one transaction.
     * @param amountDscToBurn The amount of DSC tokens to burn
     * @param tokenCollateralAddress The address of the token to withdraw as collateral
     * @param amountCollateral The amount of the token to withdraw as collateral
     */
    function burnDSCAndRedeemCollateral(
        uint256 amountDscToBurn,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @dev Mint DSC tokens
     * @param amountDscTomint The amount of DSC tokens to mint
     * @notice Follows CEI(Checks, Effects, Interactions)
     * @notice must have more value than the minimum threshold
     * @notice must have more collateral than the value of the DSC tokens minted
     */
    function mintDSC(uint256 amountDscTomint) public moreThanZero(amountDscTomint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscTomint;

        //Revert if the value of the collateral is less than the value of the DSC tokens minted
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscTomint);

        require(minted, DSCEngine__MintDscFailed());
    }

    /**
     * @dev Burn DSC tokens
     * @param amountDscToBurn The amount of DSC tokens to burn
     */
    function burnDSC(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) nonReentrant {
        _burnDSC(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev Liquidate a user
     * @param user The address of the user to liquidate. The user must have a health factor less than 1
     * @param collateral The address of the token to withdraw as collateral
     * @param debtToCover The amount of DSC tokens to burn to improve user health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user's funds
     * @notice This function working assumes that the protocol will be roughly 200% overcollateralized
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize liquidators
     */
    function liquidate(address user, address collateral, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        require(startingUserHealthFactor < MIN_HEALTH_FACTOR, DSCEngine__HealthFactorIsOkay(startingUserHealthFactor));

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        require(
            endingUserHealthFactor > startingUserHealthFactor,
            DSCEngine__HealthFactorNotImproved(endingUserHealthFactor)
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////
    // Private & internal View Functions //
    ///////////////////////////////////

    /**
     * @dev Get the account information of a user
     * @param user The address of the user to get the account information for
     * @return totalDscMinted The total DSC minted by the user
     * @return totalCollateralValueInUsd The total collateral value in USD
     */
    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @dev Gets the health factor of a user
     * @param user The address of the user to calculate the health factor for
     * @return The health factor of the user(uint256)
     * @notice The health factor is the ratio of the value of the collateral to the value of the DSC tokens minted
     * If the health factor is less than 1, the user is insolvent
     * If the health factor is greater than 1, the user is solvent
     */
    function _healthFactor(address user) internal view returns (uint256) {
        // total dsc minted
        // total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    /**
     * @dev Calculate the health factor of a user
     * @param totalDscMinted The total DSC minted by the user
     * @param totalCollateralValueInUsd The total collateral value in USD
     * @return The health factor of the user(uint256)
     * @notice The health factor is the ratio of the value of the collateral to the value of the DSC tokens minted
     * If the health factor is less than 1, the user is insolvent
     * If the health factor is greater than 1, the user is solvent
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @dev Revert if the health factor of a user is less than the minimum health factor
     * @param user The address of the user to revert if the health factor is less than the minimum health factor
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        require(userHealthFactor >= MIN_HEALTH_FACTOR, DSCEngine__HealthFactorIsTooLow(userHealthFactor));
    }

    /**
     * @dev Redeem collateral from the system
     * @param from The address of the user to redeem collateral from
     * @param to The address of the user to redeem collateral to
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of the token to redeem as collateral
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        require(success, DSCEngine__TransferFailed());
    }

    /**
     * @dev Burn DSC tokens
     * @dev Low level function to burn DSC tokens. Do not call unless the function calling it has checked for broken health factor
     * @param amountDscToBurn The amount of DSC tokens to burn
     * @param onBehalfOf The address of the user to burn DSC tokens on behalf of
     */
    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        require(success, DSCEngine__TransferFailed());

        i_dsc.burn(amountDscToBurn);
    }

    ////////////////////////
    // Public and External View Functions
    ////////////////////////
    /**
     * @notice Get the value of the collateral of a user in USD
     * @param user The address of the user to get the collateral value for
     * @return collateralValueInUsd The total value of user's the collateral in USD
     */
    function getAccountCollateralValue(address user) public view returns (uint256 collateralValueInUsd) {
        collateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            collateralValueInUsd += getUsdValue(token, amount);
        }
        return collateralValueInUsd;
    }

    /**
     * @notice This function performs an operation with a specified token and amount.
     * @param token The address of the token to be used.
     * @param amount The amount of the token to be used.
     * @return The value of the token in USD.
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        address priceFeedAddress = s_priceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice This function converts a specified amount DSC(in wei) to its collateral value.
     * @param token The address of the token to be used.
     * @param usdAmountinWei The amount of the token to be converted.
     * @return The value of DSC in collateral value.
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountinWei) public view returns (uint256) {
        address priceFeedAddress = s_priceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountinWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Get the address of the DSC contract
     * @return The address of the DSC contract
     */
    function getDscAddress() public view returns (address) {
        return address(i_dsc);
    }

    /**
     * @param user The address of the user to get the collateral token balance for
     * @param token The address of the token to be used.
     */
    function getUserCollateralTokenBalance(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
