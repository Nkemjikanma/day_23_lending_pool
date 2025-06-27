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
    error LendingPool__InvalidDepositAmount();
    error LendingPool__AssetNotAccepted();
    error LendingPool__NotEnoughLiquidity();
    error LendingPool__NoBorrowsForAsset();

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

    event CollateralDeposited(
        address indexed _sender,
        address indexed _token,
        uint256 _value
    );
    event Borrowed(
        address indexed _sender,
        address indexed _token,
        uint256 _value
    );

    event LoanRepaid(
        address indexed _sender,
        address indexed _token,
        uint256 _effectivePayment,
        int256 _interestPayment
    );

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

    function depositCollateral(address token, uint256 amount) external payable {
        if (msg.value <= 0 || amount <= 0) {
            revert LendingPool__InvalidDepositAmount();
        }

        if (!supportedAssets[token]) {
            revert LendingPool__AssetNotAccepted();
        }

        bool tokenExist = false;
        for (
            uint256 i = 0;
            i < userAccount[msg.sender].collateralAssets.length;
            i++
        ) {
            if (token == userAccount[msg.sender].collateralAssets[i]) {
                tokenExist = true;
                break;
            }
        }

        if (!tokenExist) {
            userAccount[msg.sender].collateralAssets.push(token);
        }

        userCollateral[msg.sender][token] += amount;
        totalDeposits[msg.sender] += amount;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(
        address token,
        uint256 amount
    ) external sufficientCollateral(msg.sender) {
        if (msg.value <= 0 || amount <= 0) {
            revert LendingPool__InvalidDepositAmount();
        }

        if (!supportedAssets[token]) {
            revert LendingPool__AssetNotAccepted();
        }

        if (totalDeposits[token] - totalBorrows < amount) {
            revert LendingPool__NotEnoughLiquidity();
        }

        bool tokenExists = false;
        for (
            uint i = 0;
            i < userAccounts[msg.sender].borrowedAssets.length;
            i++
        ) {
            if (userAccounts[msg.sender].borrowedAssets[i] == token) {
                tokenExists = true;
                break;
            }
        }

        if (!tokenExists) {
            userAccounts[msg.sender].borrowedAssets.push(token);
        }

        userBorrows[msg.sender][token] += amount;
        borrowTimestamp[msg.sender][token] = block.timestamp;
        totalBorrows[token] += amount;
        userAccounts[msg.sender].totalBorrowsUSD += getAssetPrice(
            amount,
            AggregatorV3Interface(token)
        );

        Loan memory userLoan = Loan({
            borrowAsset: token,
            borrowAmount: amount,
            startTimestamp: block.timestamp,
            interestRate: assetConfigs[token].borrowInterestRate,
            active: true,
            amountRepaid: 0
        });

        userLoans[msg.sender].push(newLoan);

        // Transfer tokens to user
        if (token == address(0)) {
            // For ETH - confirm if this works same for L2 eth
            payable(msg.sender).transfer(amount);
        } else {
            // For ERC20 tokens
            IERC20(token).transfer(msg.sender, amount);
        }

        emit Borrowed(msg.sender, token, amount);
    }

    function repay(address token, uint256 amount) external payable {
        if (msg.value <= 0 || amount <= 0) {
            revert LendingPool__InvalidDepositAmount();
        }

        if (!supportedAssets[token]) {
            revert LendingPool__AssetNotAccepted();
        }

        // if user has any borrows for this token
        if (userBorrows[msg.sender][token] == 0) {
            revert LendingPool__NoBorrowsForAsset();
        }

        uint256 interest = calculateAccuredInterest(msg.sender, token, amount);
        uint256 totalDebt = userBorrows[msg.sender][token] + interest;

        uint256 effectiveRepayment = amount > totalDebt ? totalDebt : amount;
        uint256 principalpayment = effectiveRepayment > interest
            ? effectiveRepayment - interest
            : 0;
        uint256 interestRepayment = effectiveRepayment > interest
            ? interest
            : effectiveRepayment;

        totalBorrows[token] -= principalpayment;
        userBorrows[msg.sender][token] -= principalRepayment;

        uint256 remainingRepayment = principalRepayment;
        for (
            uint i = 0;
            i < userLoans[msg.sender].length && remainingRepayment > 0;
            i++
        ) {
            Loan storage loan = userLoans[msg.sender][i];

            if (loan.active && loan.borrowAsset == token) {
                uint256 loanRemainingDebt = loan.borrowAmount -
                    loan.amountRepaid;

                if (loanRemainingDebt > 0) {
                    // Calculate how much to apply to this loan
                    uint256 loanRepayment = remainingRepayment >
                        loanRemainingDebt
                        ? loanRemainingDebt
                        : remainingRepayment;

                    // Update loan record
                    loan.amountRepaid += loanRepayment;
                    remainingRepayment -= loanRepayment;

                    // Check if loan is fully repaid
                    if (loan.amountRepaid >= loan.borrowAmount) {
                        loan.active = false;
                    }
                }
            }
        }

        if (userBorrows[msg.sender][token] == 0) {
            _removeAssetFromBorrowedAssets(msg.sender, token);
        }

        emit LoanRepaid(
            msg.sender,
            token,
            effectiveRepayment,
            interestRepayment
        );
    }

    function calculatePositionHealth(
        address user
    ) public view returns (PositionHealth memory) {
        PositionHealth memory health;

        // calculate collateral value
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

            collateralValueUSD += valueUSD;
        }

        // calculate borrow value
        uin256 borrowValueUSD = 0;
        for (uint256 i = 0; i < userAccount[user].borrowedAssets.length; i++) {
            address asset = userAccount[user].borrowAssets[i];
            uint256 amount = userBorrows[user][asset];

            // get interest
            uint256 interest = calculateAccuredIntest(user, asset, amount);

            uint256 totalOwed = interest + amount;
            uint256 valueUSD = getAssetPrice(
                amount,
                AggregatorV3Interface(asset)
            );
            borrowValueUSD += valueUSD;
        }

        health.collaterlValueUSD = collateralValueUSD;
        health.borrowValueUSD = borrowVAlueUSD;

        if (borrowValueUSD == 0) {
            health.healthFactor = type(uint256).max; // max value
            health.isHealthy = true;
        } else {
            health.healthFactor = (collateralValueUSD * 100) / borrowValueUSD;
            health.isHealthy = health.healthFactor >= liquidationTreshold;
        }

        return health;
    }

    function calculateAccuredInterest(
        address user,
        address asset,
        uint256 amount
    ) public view returns (uint256) {
        InterestCalculator memory assetInterest = interestModels[asset];
        uint256 borrowedAmount = userBorrows[user][asset];

        // If no borrows, return 0
        if (borrowedAmount == 0) {
            return 0;
        }

        uint256 loanTime = borrowTimestamp[user][asset];

        uint256 timeElapsed = block.timestamp - loanTime;

        // If no time has passed, return 0
        if (elapsedTime == 0) {
            return 0;
        }

        InterestCalculator memory interestModel = interestModels[asset];

        // Calculate current utilization rate to determine the dynamic interest rate
        uint256 utilizationRate = calculateUtilizationRate(asset);

        // Calculate the applicable interest rate based on utilization
        uint256 interestRate = calculateApplicableInterestRate(
            utilizationRate,
            interestModel
        );

        // Convert annual interest rate to per-second rate
        // Division by 10000 to convert from basis points to decimal
        // Division by 31536000 (seconds in a year)
        uint256 ratePerSecond = (interestRate * 1e14) / 31536000; // 1e14 = 10000 * 1e10 for precision

        // Calculate compound interest: principal * ((1 + ratePerSecond) ^ elapsedTime) - principal
        // For Solidity, we use the approximation: principal * (1 + ratePerSecond * elapsedTime)
        uint256 interest = (borrowedAmount * ratePerSecond * elapsedTime) /
            1e10;

        return interest;
    }

    function calculateUtilizationRate(
        address asset
    ) internal view returns (uint256) {
        uint256 totalDepositForAsset = totalDepoits[asset];

        if (totalDepositForAsset == 0) {
            return 0;
        }

        uint256 totalBorrowsForAsset = totalBorrows[asset];

        // utilizaiton rate in basis points; (totalBorrows * 10000) / totalDeposits

        return (totalBorrowsForAsset * 10000) / totalDepositsForAsset;
    }

    function calculateApplicabeInterestRate(
        uint256 utilizationRate,
        InterestCalculator memory model
    ) internal pure returns (uin256) {
        if (utilizationRate <= model.optimalUtilizationRate) {
            // Calculate: baseRate + (utilizationRate * slope1) / optimalUtilizationRate
            return
                model.baseRatePerYear +
                ((utilizationRate * model.slopeRate1) /
                    model.optimalUtilizationRate);
        }
        // If utilization is above the optimal rate, use the second (steeper) slope
        else {
            // Calculate: baseRate + slope1 + ((utilizationRate - optimalRate) * slope2) / (10000 - optimalRate)
            uint256 excessUtilization = utilizationRate -
                model.optimalUtilizationRate;
            uint256 remainingUtilization = 10000 - model.optimalUtilizationRate;

            return
                model.baseRatePerYear +
                model.slopeRate1 +
                ((excessUtilization * model.slopeRate2) / remainingUtilization);
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

    function _removeAssetFromBorrowedAssets(
        address user,
        address token
    ) internal {
        UserAccount storage account = userAccounts[user];
        for (uint i = 0; i < account.borrowedAssets.length; i++) {
            if (account.borrowedAssets[i] == token) {
                // Replace with the last element and pop
                if (i < account.borrowedAssets.length - 1) {
                    account.borrowedAssets[i] = account.borrowedAssets[
                        account.borrowedAssets.length - 1
                    ];
                }
                account.borrowedAssets.pop();
                break;
            }
        }
    }
}
