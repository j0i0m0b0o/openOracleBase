// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLending_FIRST_DRAFT.sol";
import "../../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}

/// @title LiquidationTestRefi
/// @notice Same liquidation tests as LiquidationTest, but on a refinanced loan
contract LiquidationTestRefi is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken; // collateral token
    MockERC20 internal borrowToken; // loan token

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);   // original lender
    address internal lender2 = address(0x7);   // refi lender (new lender after refi)
    address internal liquidator = address(0x3);
    address internal disputer1 = address(0x4);
    address internal disputer2 = address(0x5);
    address internal settler = address(0x6);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    // Loan parameters
    uint256 constant SUPPLY_AMOUNT = 100 ether;
    uint256 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint32 constant INTEREST_RATE = 1e8;         // 10% annual
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint256 constant STAKE = 100;                // 1%

    // Oracle parameters
    uint256 constant ORACLE_EXACT_TOKEN1 = SUPPLY_AMOUNT / 10; // 10 ether
    uint256 constant ORACLE_SETTLEMENT_TIME = 300;
    uint256 constant ORACLE_DISPUTE_DELAY = 60;
    uint24 constant ORACLE_PROTOCOL_FEE = 100000; // 1%
    uint16 constant ORACLE_MULTIPLIER = 200;     // 2x

    // Liquidation expected params
    uint256 constant EXPECTED_STAKE = SUPPLY_AMOUNT * STAKE / 10000; // 1 ether
    uint256 constant EXPECTED_INITIAL_LIQUIDITY = ORACLE_EXACT_TOKEN1; // 10 ether

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        // Fund all accounts
        supplyToken.transfer(borrower, 10000 ether);
        supplyToken.transfer(lender1, 10000 ether);
        supplyToken.transfer(lender2, 10000 ether);
        supplyToken.transfer(liquidator, 10000 ether);
        supplyToken.transfer(disputer1, 10000 ether);
        supplyToken.transfer(disputer2, 10000 ether);

        borrowToken.transfer(borrower, 10000 ether);
        borrowToken.transfer(lender1, 10000 ether);
        borrowToken.transfer(lender2, 10000 ether);
        borrowToken.transfer(liquidator, 10000 ether);
        borrowToken.transfer(disputer1, 10000 ether);
        borrowToken.transfer(disputer2, 10000 ether);

        vm.deal(borrower, 100 ether);
        vm.deal(lender1, 100 ether);
        vm.deal(lender2, 100 ether);
        vm.deal(liquidator, 100 ether);
        vm.deal(disputer1, 100 ether);
        vm.deal(disputer2, 100 ether);
        vm.deal(settler, 100 ether);

        // Approvals for lending
        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(borrower);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender1);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender2);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(liquidator);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        borrowToken.approve(address(lending), type(uint256).max);

        // Approvals for oracle (disputers and liquidator)
        vm.prank(disputer1);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(disputer1);
        borrowToken.approve(address(oracle), type(uint256).max);

        vm.prank(disputer2);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(disputer2);
        borrowToken.approve(address(oracle), type(uint256).max);

        vm.prank(liquidator);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(liquidator);
        borrowToken.approve(address(oracle), type(uint256).max);

        vm.prank(lender2);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(lender2);
        borrowToken.approve(address(oracle), type(uint256).max);

        // Seed lending contract with unrelated funds
        supplyToken.transfer(address(lending), UNRELATED_SUPPLY);
        borrowToken.transfer(address(lending), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Helper: Calculate total owed at maturity
    // -------------------------------------------------------------------------
    function calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint256) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return principal + interest;
    }

    // -------------------------------------------------------------------------
    // Helper: Calculate total owed now (for in-progress loans)
    // -------------------------------------------------------------------------
    function calculateOwedNow(uint256 principal, uint32 rate, uint48 term, uint256 start) internal view returns (uint256) {
        uint256 year = 365 days;
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed > term) elapsed = term;
        uint256 interest = (principal * elapsed * rate) / (1e9 * year);
        return principal + interest;
    }

    // -------------------------------------------------------------------------
    // Helper: Setup a REFINANCED loan ready for liquidation
    // Returns the lendingId and the new borrow amount after refi
    // The current lender is lender2 (lender1 was the original)
    // -------------------------------------------------------------------------
    function setupRefinancedLoanForLiquidation() internal returns (uint256 lendingId, uint256 refiBorrowAmount) {
        // Step 1: Borrower requests borrow
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            openLending.OracleParams(300, 100, 10)
        );

        // Step 2: Lender1 offers with allowAnyLiquidator = true
        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Step 3: Borrower accepts lender1's offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // Step 4: Fast forward partway through the loan
        vm.warp(block.timestamp + 10 days);

        // Step 5: Borrower opens refi
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Step 6: Lender2 offers refi (pays off lender1's debt)
        uint256 owedToLender1 = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender2);
        (uint256 refiOffer, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            true,          // allowAnyLiquidator
            0,             // repaidDebtExpected
            0,             // extraDemandedExpected
            0              // minSupplyPostRefi
        );

        // Step 7: Borrower accepts refi
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOffer, refiNonce);

        refiBorrowAmount = owedToLender1;

        return (lendingId, refiBorrowAmount);
    }

    // =========================================================================
    // TEST 1: Liquidation succeeds with equity remaining - on refi'd loan
    // =========================================================================
    function testRefiLiquidation_SuccessWithEquityRemaining() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        // Fast forward some time to accrue interest
        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Track all balances before
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Liquidation price: debt > 80% but < 100% of collateral
        uint256 oracleAmount2 = 8 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 1e15 + 1}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            oracleAmount2,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        // Verify in liquidation
        openLending.LendingView memory loanDuring = lending.getLending(lendingId);
        assertTrue(loanDuring.inLiquidation, "Loan should be in liquidation");
        assertEq(loanDuring.liquidator, liquidator, "Liquidator should be set");

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Dispute 1: generates protocol fee on 10 ether supplyToken (1% = 0.1 ether)
        vm.warp(block.timestamp + 120);
        vm.prank(disputer1);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            20 ether,
            12 ether,
            disputer1,
            8 ether,
            stateHash
        );

        // Dispute 2: generates protocol fee on 20 ether supplyToken (1% = 0.2 ether)
        // Final ratio: 40/32 = 1.25 supply per borrow
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer2);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            40 ether,
            32 ether,
            disputer2,
            12 ether,
            stateHash
        );

        // Settle
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify loan finished
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after liquidation");

        // Calculate expected collateral distribution
        // Final oracle: 40 supply = 32 borrow => 1.25 supply per borrow
        uint256 debtNow = calculateOwedNow(refiBorrowAmount, INTEREST_RATE, LOAN_TERM, loanBefore.start);
        uint256 debtInSupplyTerms = (debtNow * 40 ether) / 32 ether;

        // Verify liquidation threshold breached but has equity
        uint256 liqThresh = SUPPLY_AMOUNT * LIQUIDATION_THRESHOLD / 1e7;
        assertTrue(debtInSupplyTerms > liqThresh, "Should have breached liquidation threshold");
        assertTrue(debtInSupplyTerms < SUPPLY_AMOUNT, "Should have equity remaining");

        // Equity split: buffer / 2 to each, liquidator gets remainder for odd amounts
        uint256 buffer = SUPPLY_AMOUNT - debtInSupplyTerms;
        uint256 lenderPiece = buffer / 2;
        uint256 liquidatorPiece = buffer - lenderPiece;

        // Protocol fees from disputes (1% of swapped token amounts)
        // Dispute 1: 1% of 10 ether = 0.1 ether
        // Dispute 2: 1% of 20 ether = 0.2 ether
        // Total: 0.3 ether supplyToken
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 totalSupplyFees = (10 ether * protocolFeeRate / 1e7) + (20 ether * protocolFeeRate / 1e7);

        // Fee distribution: 50% borrower, 25% lender, 25% liquidator
        uint256 borrowerFeeShare = totalSupplyFees / 2;
        uint256 lenderFeeShare = borrowerFeeShare / 2;
        uint256 liquidatorFeeShare = totalSupplyFees - borrowerFeeShare - lenderFeeShare;

        // Expected gains from lending contract
        uint256 expectedLenderCollateralGain = debtInSupplyTerms + lenderPiece;

        // Actual balance changes
        uint256 lender2SupplyGain = supplyToken.balanceOf(lender2) - lender2SupplyBefore;
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;

        // Liquidator's supply token flow:
        // 1. Spent: ORACLE_EXACT_TOKEN1 (10 ether) to oracle + tokenStake (1 ether) to lending = 11 ether
        // 2. Received when disputed: 2 * oldAmount1 + swapFee = 2 * 10 + ~0 = 20 ether
        // 3. Received from lending: liquidatorPiece + tokenStake + liquidatorFeeShare
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);
        uint256 liquidatorSpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorReceivedFromDispute = 2 * ORACLE_EXACT_TOKEN1 + (ORACLE_EXACT_TOKEN1 * 1 / 1e7);
        uint256 liquidatorReceivedFromLending = liquidatorPiece + tokenStake + liquidatorFeeShare;

        // Assert lender2 got correct collateral share + fee share
        assertEq(lender2SupplyGain, expectedLenderCollateralGain + lenderFeeShare, "Lender2 supply gain incorrect");

        // Assert borrower got their fee share (50%)
        assertEq(borrowerSupplyGain, borrowerFeeShare, "Borrower fee share incorrect");

        // Assert liquidator net change is correct
        int256 liquidatorNetChange = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorNet = int256(liquidatorReceivedFromDispute + liquidatorReceivedFromLending) - int256(liquidatorSpent);
        assertEq(liquidatorNetChange, expectedLiquidatorNet, "Liquidator net supply change incorrect");

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // =========================================================================
    // TEST 2: Liquidation succeeds with NO equity remaining (underwater)
    // =========================================================================
    function testRefiLiquidation_SuccessNoEquityRemaining() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Track all balances before
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Price that makes loan underwater (debt > 100% collateral)
        // Final ratio 20/10 = 2.0 => debt in supply terms = refiBorrowAmount * 2 (underwater)
        uint256 oracleAmount2 = 6 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 1e15 + 1}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            oracleAmount2,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // One dispute: generates protocol fee on 10 ether supplyToken (1% = 0.1 ether)
        // Final ratio: 20/10 = 2.0 supply per borrow (underwater)
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        vm.prank(disputer1);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            20 ether,
            10 ether,
            disputer1,
            6 ether,
            stateHash
        );

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished");

        // Verify underwater: debt in supply terms > collateral
        uint256 debtNow = calculateOwedNow(refiBorrowAmount, INTEREST_RATE, LOAN_TERM, loanBefore.start);
        uint256 debtInSupplyTerms = (debtNow * 20 ether) / 10 ether;
        assertTrue(debtInSupplyTerms > SUPPLY_AMOUNT, "Should be underwater");

        // Protocol fees from dispute: 1% of 10 ether = 0.1 ether
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 totalSupplyFees = 10 ether * protocolFeeRate / 1e7;

        // Fee distribution: 50% borrower, 25% lender, 25% liquidator
        uint256 borrowerFeeShare = totalSupplyFees / 2;
        uint256 lenderFeeShare = borrowerFeeShare / 2;
        uint256 liquidatorFeeShare = totalSupplyFees - borrowerFeeShare - lenderFeeShare;

        // Actual balance changes
        uint256 lender2SupplyGain = supplyToken.balanceOf(lender2) - lender2SupplyBefore;
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);

        // Liquidator's supply token flow:
        // 1. Spent: ORACLE_EXACT_TOKEN1 (10 ether) + tokenStake (1 ether) = 11 ether
        // 2. Received when disputed: 2 * 10 + swapFee = 20 ether
        // 3. Received from lending: tokenStake + liquidatorFeeShare
        uint256 liquidatorSpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorReceivedFromDispute = 2 * ORACLE_EXACT_TOKEN1 + (ORACLE_EXACT_TOKEN1 * 1 / 1e7);
        uint256 liquidatorReceivedFromLending = tokenStake + liquidatorFeeShare;

        // Assert lender2 got all collateral + 25% fee share
        assertEq(lender2SupplyGain, SUPPLY_AMOUNT + lenderFeeShare, "Lender2 should get all collateral + 25% fee share");

        // Assert borrower got their fee share (50%)
        assertEq(borrowerSupplyGain, borrowerFeeShare, "Borrower fee share incorrect");

        // Assert liquidator net change is correct
        int256 liquidatorNetChange = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorNet = int256(liquidatorReceivedFromDispute + liquidatorReceivedFromLending) - int256(liquidatorSpent);
        assertEq(liquidatorNetChange, expectedLiquidatorNet, "Liquidator net supply change incorrect");

        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // =========================================================================
    // TEST 3: Liquidation FAILS - price doesn't breach threshold
    // =========================================================================
    function testRefiLiquidation_FailsPriceDoesntLiquidate() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Safe price - debt < 80% collateral
        uint256 oracleAmount2 = 12 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            oracleAmount2,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        vm.prank(disputer1);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            20 ether,
            30 ether,
            disputer1,
            12 ether,
            stateHash
        );

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Loan NOT finished, just out of liquidation
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.finished, "Loan should NOT be finished");
        assertFalse(loanAfter.inLiquidation, "Should no longer be in liquidation");
        assertTrue(loanAfter.active, "Loan should still be active");

        // Borrower's collateral increased by liquidator's stake
        assertEq(loanAfter.supplyAmount, SUPPLY_AMOUNT + tokenStake, "Borrower should gain liquidator stake");

        // Contract holds increased collateral
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY + SUPPLY_AMOUNT + tokenStake,
            "Contract should have unrelated + new collateral"
        );
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // =========================================================================
    // TEST 4: Protocol fee distribution - on refi'd loan
    // Tests fees in BOTH supply token and borrow token with exact assertions
    // =========================================================================
    function testRefiLiquidation_ProtocolFeeDistribution() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Track ALL balances before for BOTH tokens
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 liquidatorBorrowBefore = borrowToken.balanceOf(liquidator);

        uint256 oracleAmount2 = 8 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 1e15 + 1}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            oracleAmount2,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.warp(block.timestamp + 120);

        // Dispute 1: swapping supplyToken - generates fee on 10 ether supplyToken (1% = 0.1 ether)
        vm.prank(disputer1);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            20 ether,
            12 ether,
            disputer1,
            8 ether,
            stateHash
        );

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        // Dispute 2: swapping borrowToken - generates fee on 12 ether borrowToken (1% = 0.12 ether)
        // Final ratio: 40/20 = 2.0 (underwater)
        vm.prank(disputer2);
        oracle.disputeAndSwap(
            reportId,
            address(borrowToken),
            40 ether,
            20 ether,
            disputer2,
            12 ether,
            stateHash
        );

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished");

        // =====================================================================
        // SUPPLY TOKEN FEE DISTRIBUTION
        // Dispute 1 generated: 1% of 10 ether = 0.1 ether supplyToken fees
        // Distribution: 50% borrower, 25% lender, 25% liquidator
        // =====================================================================
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 supplyFees = 10 ether * protocolFeeRate / 1e7; // 0.1 ether

        uint256 borrowerSupplyFeeShare = supplyFees / 2; // 0.05 ether
        uint256 lenderSupplyFeeShare = borrowerSupplyFeeShare / 2; // 0.025 ether
        uint256 liquidatorSupplyFeeShare = supplyFees - borrowerSupplyFeeShare - lenderSupplyFeeShare; // 0.025 ether

        // Underwater: lender gets all collateral (SUPPLY_AMOUNT) + lenderFeeShare
        uint256 lender2SupplyGain = supplyToken.balanceOf(lender2) - lender2SupplyBefore;
        assertEq(lender2SupplyGain, SUPPLY_AMOUNT + lenderSupplyFeeShare, "Lender2 supply gain incorrect");

        // Borrower gets only supply fee share
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;
        assertEq(borrowerSupplyGain, borrowerSupplyFeeShare, "Borrower supply fee share incorrect");

        // Liquidator supply flow:
        // 1. Spent: ORACLE_EXACT_TOKEN1 (10 ether) + tokenStake (1 ether) = 11 ether
        // 2. Received from dispute: 2 * 10 + swapFee = 20 ether + dust
        // 3. Received from lending: tokenStake + liquidatorSupplyFeeShare
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);
        uint256 liquidatorSupplySpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorSupplyFromDispute = 2 * ORACLE_EXACT_TOKEN1 + (ORACLE_EXACT_TOKEN1 * 1 / 1e7);
        uint256 liquidatorSupplyFromLending = tokenStake + liquidatorSupplyFeeShare;

        int256 liquidatorSupplyNetChange = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorSupplyNet = int256(liquidatorSupplyFromDispute + liquidatorSupplyFromLending) - int256(liquidatorSupplySpent);
        assertEq(liquidatorSupplyNetChange, expectedLiquidatorSupplyNet, "Liquidator net supply change incorrect");

        // =====================================================================
        // BORROW TOKEN FEE DISTRIBUTION
        // Dispute 2 generated: 1% of 12 ether = 0.12 ether borrowToken fees
        // Distribution: 50% borrower, 25% lender, 25% liquidator
        // =====================================================================
        uint256 borrowFees = 12 ether * protocolFeeRate / 1e7; // 0.12 ether

        uint256 borrowerBorrowFeeShare = borrowFees / 2; // 0.06 ether
        uint256 lenderBorrowFeeShare = borrowerBorrowFeeShare / 2; // 0.03 ether
        uint256 liquidatorBorrowFeeShare = borrowFees - borrowerBorrowFeeShare - lenderBorrowFeeShare; // 0.03 ether

        // Borrower borrow token gain: just fee share
        uint256 borrowerBorrowGain = borrowToken.balanceOf(borrower) - borrowerBorrowBefore;
        assertEq(borrowerBorrowGain, borrowerBorrowFeeShare, "Borrower borrow fee share incorrect");

        // Lender borrow token gain: just fee share
        uint256 lender2BorrowGain = borrowToken.balanceOf(lender2) - lender2BorrowBefore;
        assertEq(lender2BorrowGain, lenderBorrowFeeShare, "Lender2 borrow fee share incorrect");

        // Liquidator borrow token flow:
        // 1. Spent: oracleAmount2 (8 ether) to oracle for initial report
        // 2. Received from lending: liquidatorBorrowFeeShare (0.03 ether)
        // Note: borrow tokens spent on oracle initial report are NOT returned when disputed
        uint256 liquidatorBorrowAfter = borrowToken.balanceOf(liquidator);
        int256 liquidatorBorrowNetChange = int256(liquidatorBorrowAfter) - int256(liquidatorBorrowBefore);
        int256 expectedLiquidatorBorrowNet = int256(liquidatorBorrowFeeShare) - int256(oracleAmount2);
        assertEq(liquidatorBorrowNetChange, expectedLiquidatorBorrowNet, "Liquidator net borrow change incorrect");

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // =========================================================================
    // TEST 5: Only lender can liquidate if allowAnyLiquidator is false
    // =========================================================================
    function testRefiLiquidation_OnlyLenderIfNotPublic() public {
        // Setup loan
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            openLending.OracleParams(300, 100, 10)
        );

        // Lender1 offers with allowAnyLiquidator = true
        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        vm.warp(block.timestamp + 10 days);

        // Borrower opens refi
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        uint256 owedToLender1 = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        // Lender2 offers refi with allowAnyLiquidator = FALSE
        vm.prank(lender2);
        (uint256 refiOffer, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            false,         // allowAnyLiquidator = FALSE
            0,             // repaidDebtExpected
            0,             // extraDemandedExpected
            0              // minSupplyPostRefi
        );

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOffer, refiNonce);

        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Non-lender tries to liquidate - should fail
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "wrong liquidator"));
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            8 ether,
            owedToLender1,
            loan.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        // Lender2 (current lender) can liquidate
        vm.prank(lender2);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            8 ether,
            owedToLender1,
            loan.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.inLiquidation, "Lender2 should be able to start liquidation");
        assertEq(loanAfter.liquidator, lender2, "Liquidator should be lender2");
    }

    // =========================================================================
    // TEST 6: Cannot liquidate expired refi'd loan
    // =========================================================================
    function testRefiLiquidation_CannotLiquidateExpired() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Fast forward past expiration
        vm.warp(loan.start + loan.term + 1);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "arrangement expired"));
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            8 ether,
            refiBorrowAmount,
            loan.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );
    }

    // =========================================================================
    // TEST 7: Cannot repay or topup during liquidation on refi'd loan
    // =========================================================================
    function testRefiLiquidation_CannotRepayOrTopupDuringLiquidation() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        vm.warp(block.timestamp + 5 days);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Start liquidation
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            8 ether,
            refiBorrowAmount,
            loan.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        // Try to repay - should fail
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "in liquidation"));
        lending.repayDebt(lendingId, 10 ether);

        // Try to topup - should fail
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "in liquidation"));
        lending.topUpCollateral(lendingId, 10 ether);
    }

    // =========================================================================
    // TEST 8: Grace period after failed liquidation near maturity - on refi'd loan
    // =========================================================================
    function testRefiLiquidation_GracePeriodAfterFailedLiquidationNearMaturity() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Fast forward to near maturity (within 5 minutes)
        vm.warp(loanBefore.start + loanBefore.term - 200);

        // Liquidate with safe price
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.finished, "Loan should not be finished");
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set");

        // Borrower can repay past original maturity but within grace
        vm.warp(block.timestamp + 100);

        uint256 totalOwed = calculateOwedNow(refiBorrowAmount, INTEREST_RATE, LOAN_TERM, loanAfter.start);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed + 1 ether);

        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Borrower should be able to repay during grace period");
    }

    // =========================================================================
    // TEST 9: Liquidation runs PAST maturity - grace period = 300 + 2x duration
    // =========================================================================
    function testRefiGracePeriod_LiquidationRunsPastMaturity() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Fast forward to 1 day before maturity
        vm.warp(loanBefore.start + loanBefore.term - 1 days);

        // Start liquidation with safe price
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        openLending.LendingView memory loanDuring = lending.getLending(lendingId);
        uint256 liquidationStartTimestamp = loanDuring.liquidationStart;

        uint256 reportId = oracle.nextReportId() - 1;

        // Warp PAST maturity (2 days)
        vm.warp(block.timestamp + 2 days);

        uint256 settlementTimestamp = block.timestamp;

        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        assertFalse(loanAfter.finished, "Loan should not be finished");
        assertFalse(loanAfter.inLiquidation, "Should not be in liquidation");

        // Verify exact grace period calculation
        uint256 liquidationDuration = settlementTimestamp - liquidationStartTimestamp;
        uint256 expectedGracePeriod = 300 + liquidationDuration * 2;

        assertEq(liquidationDuration, 2 days, "Liquidation should have run for 2 days");
        assertEq(expectedGracePeriod, 300 + 172800 * 2, "Expected grace = 300 + 2*172800 = 345900");
        assertEq(loanAfter.gracePeriod, expectedGracePeriod, "Grace period must equal 300 + 2x liquidation duration");
    }

    // =========================================================================
    // TEST 10: Lender CANNOT claim during grace period - on refi'd loan
    // =========================================================================
    function testRefiGracePeriod_LenderCannotClaimDuringGrace() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        vm.warp(loanBefore.start + loanBefore.term - 200);

        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set");

        // Warp to past original maturity but within grace
        vm.warp(loanAfter.start + loanAfter.term + 100);

        // Lender2 tries to claim - should fail
        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "not expired"));
        lending.claimCollateral(lendingId);
    }

    // =========================================================================
    // TEST 11: After grace period expires, lender CAN claim - on refi'd loan
    // =========================================================================
    function testRefiGracePeriod_LenderCanClaimAfterGraceExpires() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        vm.warp(loanBefore.start + loanBefore.term - 200);

        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set");

        // Warp to AFTER grace expires
        vm.warp(loanAfter.start + loanAfter.term + loanAfter.gracePeriod + 1);

        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Lender2 claims
        vm.prank(lender2);
        lending.claimCollateral(lendingId);

        // Lender2 should get collateral + liquidator stake
        assertEq(
            supplyToken.balanceOf(lender2),
            lender2SupplyBefore + SUPPLY_AMOUNT + tokenStake,
            "Lender2 should receive collateral after grace expires"
        );
    }

    // =========================================================================
    // TEST 12: Borrower can repay during grace period - on refi'd loan
    // =========================================================================
    function testRefiGracePeriod_BorrowerCanRepayDuringGrace() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        vm.warp(loanBefore.start + loanBefore.term - 200);

        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        // Warp to past original maturity but within grace
        uint256 timeInGrace = loanAfter.start + loanAfter.term + (loanAfter.gracePeriod / 2);
        vm.warp(timeInGrace);

        uint256 totalOwed = calculateOwedNow(refiBorrowAmount, INTEREST_RATE, LOAN_TERM, loanAfter.start);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed + 1e18);

        // Borrower gets collateral + liquidator stake back
        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after repay");
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT + tokenStake,
            "Borrower should get collateral + liquidator stake back"
        );
    }

    // =========================================================================
    // TEST 13: Cannot start new liquidation past maturity but within grace
    // =========================================================================
    function testRefiGracePeriod_CannotLiquidateDuringGrace() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoanForLiquidation();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        vm.warp(loanBefore.start + loanBefore.term - 200);

        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether,
            refiBorrowAmount,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        // Warp to past original maturity but within grace
        vm.warp(loanAfter.start + loanAfter.term + 100);

        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;
        uint256 newSupplyAmount = SUPPLY_AMOUNT + tokenStake;

        // Expected params based on new supply amount
        uint256 newExpectedStake = newSupplyAmount * STAKE / 10000;
        uint256 newExpectedInitialLiquidity = newSupplyAmount / 10;

        // Try to liquidate again - should fail
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "arrangement expired"));
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            newSupplyAmount,
            0,
            8 ether,
            refiBorrowAmount,
            loanAfter.start,
            newExpectedStake,
            newExpectedInitialLiquidity
        );
    }
}
