// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Deposit assests as collateral
// Borrow other assets against their collateral
// repay loan with interest
// withdraw collateral when loans are repaid.

contract LendingPoolProxy {
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

    constructor() {
        owner = msg.sender;
    }

    modifier sufficientCollateral(address user) {
        if()
    }
}
