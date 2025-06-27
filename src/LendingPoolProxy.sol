// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Deposit assests as collateral
// Borrow other assets against their collateral
// repay loan with interest
// withdraw collateral when loans are repaid.

contract LendingPoolProxy {
    error LendingPool__InsufficientCollateral();
    error LendingPool_BelowMinimumRatio();
    error LendingPool__StalePriceData();
    error LendingPool__ErrorInPrice();

    address public owner;

    // protocol fee percentage - bais points where 100 = 1%
    uint256 public protocolFeePercentage;

    // min collateralization ratio - in percentage wher 150 == 150%
    uint256 public minCollateralRation;

    // liqudation treshold - slightly below min collateral ration eg 125%
    uint256 public liquidationTreshold;

    // Liquidation bonus for liquidators - in basis points
    uint256 public liquidationBonus;

    struct AssetConfig {
        bool canBeCollateral;
        uint256 ltv; // loan-to-value. 7000 means you can borrow 70%
        uint256 borrowInterestRate; // interest rate per year
        uint256 collateralFactor; // how much the asset is valued when used as collateral;
        address priceFeed; //price feed address from oracles
    }

    struct UserAccount {
        address[] collateralAssets; // array of asset addresses user has deposited as collateralAssets
        address[] borrowedAssets; // array of sset addresses user has borrowed
        bool liquidated;
        uint256 totalBorrowsUSD;
    }

    struct Loan {
        address borrowAsset; // addres of borrowed token
        uint256 borrowAmount; // amount borrowed
        uint256 startTimestamp; // time when load was taken
        uint256 interestRate; // interest reste at the time of borrowing - in basis points
        bool active; //
        uint256 amountRepaid; // amoount repaid so far
    }

    // Users position health
    struct PositionHealth {
        uint256 collateralValueUSD; //total value of collateral
        uint256 borrowValueUSD;
        uint256 healthFactor; // collateralValueUSD * 100 / borrowValueUSD - if bellow 100 can be liquidated
        bool isHealthy; //  whether position is healthy
    }

    struct InterestCalculator {
        uint256 baseRatePerYear; // base interest rate per year in basis points
        uint256 optimalUtilizationRate; // in basis points
        uint256 slopeRate1; // slope of interest rate when utilization is below optimal
        uint256 slopeRate2; // slope of interest rate when utilization is above optimal
    }

    struct ProtocolMetrics {
        uint256 totalValueLockedUSD; // total value lock in protocol
        uint256 totalValueBorrowedUSD; // total borrowed from protocol
        uint256 utilizationRate; // totalValueBorrowedUSD * 10000 / totalValueLockedUSD
        uint256 totalFees; // total accumulated protoco fees
    }

    struct LiquidationEvent {
        address liquidator;
        address liquidatedUser;
        address debtAsset; // debt asset that was repaid
        uint256 debtAmount; // amount of debt that was repaid
        address collateralAsset; // collateral asset that was seized
        uint256 collateralAmount; // amount of collateral seized
        uint256 timestamp; // time when liquidation occured
        uint256 healtFactorAtLiquidation; // health factor at time of liquidation
    }

    // user to account data
    mapping(address => UserAccount) public userAccounts;

    //mapping user to loans
    mapping(address => Loan[]) public userLoans;

    // mapping to tract liquidation history
    mapping(address => mapping(uint256 => LiquidationEvent))
        public liqudationHistory;

    // mapping to track interest ratte model per asset
    mapping(address => InterestCalculator) public interestModels;

    // tack last interest accural timestamp per Asset
    mapping(address => uint256) public lastInterestAccuralTimestamp;

    // mapping of supported assets
    mapping(address => bool) public supportedAssets;

    mapping(address => AssetConfig) public assetConfigs;

    //mapping to track user collateral deposits
    mapping(address => mapping(address => uint256)) public userCollateral;

    mapping(address => mapping(address => uint256)) public userBorrows;

    // mapping to track when user borrowed for interest calc
    mapping(address => mapping(address => uint256)) public borrowTimestamp;

    mapping(address => uint256) public totalDeposits;

    mapping(address => uint256) public totalBorrows;

    modifier sufficientCollateral(address user) {
        PositionHealth memory health = calculatePositionHealth(user);

        if (!health.isHealthy) {
            revert LendingPool__InsufficientCollateral();
        }

        if (health.healthFactor < minCollateralRation) {
            revert LendingPool_BelowMinimumRatio();
        }

        _;
    }

    address constant BTCUSD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address constant ethUsdPriceFeed =
        0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address constant USDCUSD = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    constructor() {
        owner = msg.sender;

        // protocol parameters
        protocolFeePercentage = 50; // 0.5%
        minCollateralRation = 150; // 150% minimum collateralization ratio
        liquidationTreshold = 125; // 125% liquidation threshold
        liquidationBonus = 500; // 5% bonus for liquidators

        address ethUsdPriceFeed = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
        supportedAssets[address(0)] = true;
        assetConfigs[address(0)] = AssetConfig({
            canBeCollateral: true,
            ltv: 7500, // 75% loan-to-value
            borrowInterestRate: 500, // 5% base annual interest
            collateralFactor: 8000, // 80% of value counted as collateral
            priceFeed: ethUsdPriceFeed
        });

        address btcPriceFeed = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
        address wbtc = 0x66194F6C999b28965E0303a84cb8b797273B6b8b;
        supportedAssets[wbtc] = true;
        assetConfigs[wbtc] = AssetConfig({
            canBeCollateral: true,
            ltv: 7000, // 70% loan-to-value (slightly lower than ETH)
            borrowInterestRate: 400, // 4% base annual interest
            collateralFactor: 7500, // 75% of value counted as collateral
            priceFeed: btcUsdPriceFeed
        });

        address usdcPriceFeed = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        supportedAssets[usdc] = true;
        assetConfigs[usdc] = AssetConfig({
            canBeCollateral: true,
            ltv: 8500, // 85% loan-to-value (higher as it's a stablecoin)
            borrowInterestRate: 300, // 3% base annual interest
            collateralFactor: 9000, // 90% of value counted as collateral
            priceFeed: usdcUsdPriceFeed
        });

        // rate models for each asset
        interestModels[address(0)] = InterestCalculator({
            baseRatePerYear: 200, // 2%
            optimalUtilizationRate: 8000, // 80%
            slopeRate1: 400, // 4%
            slopeRate2: 3000 // 30%
        });

        interestModels[wbtc] = InterestCalculator({
            baseRatePerYear: 100, // 1%
            optimalUtilizationRate: 8000, // 80%
            slopeRate1: 300, // 3%
            slopeRate2: 3000 // 30%
        });

        interestModels[usdc] = InterestCalculator({
            baseRatePerYear: 50, // 0.5%
            optimalUtilizationRate: 9000, // 90%
            slopeRate1: 250, // 2.5%
            slopeRate2: 2000 // 20%
        });

        //interest accrual timestamps
        lastInterestAccuralTimestamp[address(0)] = block.timestamp;
        lastInterestAccuralTimestamp[wbtc] = block.timestamp;
        lastInterestAccuralTimestamp[usdc] = block.timestamp;
    }

    function calculatePositionHealth(
        address user
    ) public view returns (PositionHealth memory) {
        PositionHealth memory health;

        uint256 collateralValueUSD = 0;

        for (
            uint256 i = 0;
            i < userAccounts[user].collateralAssets.length;
            i++
        ) {
            address asset = userAccounts[user].collateralAssets[i];
            uint256 amount = userCollateral[user][asset];
            uint256 valueUSD = getAssetPrice(
                amount,
                AggregatorV3Interface(asset)
            );

            // apply collateral factor
            valueUSD =
                (valueUSD * assetConfigs[assert].collateralFactor) /
                1000;
        }
    }

    function getAssetPrice(
        uint256 amount,
        AggregatorV3Interface asset
    ) public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = asset.latestRoundData();

        if (price <= 0) {
            revert LendingPool__ErrorInPrice();
        }

        if (updatedAt < block.timestamp - 1 hours) {
            revert LendingPool__StalePriceData();
        }

        uint256 assetInUSD = (amount * uint256(price)) /
            (10 ** asset.decimals());

        return assetInUSD;
    }
}
