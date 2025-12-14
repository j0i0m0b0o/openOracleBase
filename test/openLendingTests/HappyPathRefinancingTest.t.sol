// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLending_FIRST_DRAFT.sol";
import "../../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Same tests as HappyPathTest but on a loan that has been refinanced.
 *         Verifies that all standard operations work correctly post-refi.
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract HappyPathRefinancingTest is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);  // Original lender
    address internal lender2 = address(0x3);  // Refi lender
    address internal settler = address(0x4);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Original loan parameters
    uint256 constant SUPPLY_AMOUNT = 100e18;
    uint256 constant BORROW_AMOUNT = 50e18;
    uint48 constant LOAN_TERM = 30 days;
    uint32 constant INTEREST_RATE = 1e8; // 10% annual
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint256 constant STAKE = 100; // 1%

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        // Fund accounts
        supplyToken.transfer(borrower, 10000e18);
        borrowToken.transfer(borrower, 10000e18);
        borrowToken.transfer(lender1, 10000e18);
        borrowToken.transfer(lender2, 10000e18);

        // Approvals
        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(borrower);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);

        // Seed unrelated funds
        supplyToken.transfer(address(lending), UNRELATED_SUPPLY);
        borrowToken.transfer(address(lending), UNRELATED_BORROW);
    }

    // Helper: Calculate interest at maturity
    function calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint256) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return principal + interest;
    }

    // Helper: Setup a loan and immediately refinance it
    // Returns lendingId and the new borrow amount after refi
    function setupRefinancedLoan() internal returns (uint256 lendingId, uint256 refiBorrowAmount) {
        // 1. Borrower creates request
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE
        );

        // 2. Lender1 offers
        vm.prank(lender1);
        uint256 offerNum = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        // 3. Borrower accepts
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNum);

        // 4. Some time passes
        vm.warp(block.timestamp + 5 days);

        // 5. Borrower sets refi params (no extra, no pull)
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // 6. Calculate what's owed to lender1
        uint256 owedToLender1 = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);
        refiBorrowAmount = owedToLender1;

        // 7. Lender2 offers refi
        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE, // same rate
            false,         // allowAnyLiquidator
            0,             // repaidDebtExpected
            0,             // extraDemandedExpected
            0              // minSupplyPostRefi
        );

        // 8. Borrower accepts refi - lender1 gets paid, lender2 is now the lender
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        return (lendingId, refiBorrowAmount);
    }

    // =========================================================================
    // TEST: Happy path repay on refinanced loan
    // =========================================================================
    function testRefiLoan_BorrowAndRepayOnTime() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Verify refi state
        assertEq(loan.lender, lender2, "Lender should be lender2 after refi");
        assertEq(loan.borrowAmount, refiBorrowAmount, "Borrow amount should be refi amount");
        assertTrue(loan.active, "Loan should be active");
        assertFalse(loan.finished, "Loan should not be finished");
        assertEq(loan.repaidDebt, 0, "Repaid debt should be 0 after refi");

        // Track balances
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        // Calculate what borrower owes to lender2 at maturity
        uint256 totalOwed = calculateOwedAtMaturity(refiBorrowAmount, INTEREST_RATE, LOAN_TERM);

        // Repay mid-loan
        vm.warp(block.timestamp + 15 days);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed);

        // Verify loan finished
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after full repayment");

        // Verify token movements
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore - totalOwed,
            "Borrower should have paid total owed"
        );

        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should have received collateral back"
        );

        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore + totalOwed,
            "Lender2 should have received total owed"
        );

        // Verify unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    // =========================================================================
    // TEST: Late repay on refinanced loan - lender2 claims collateral
    // =========================================================================
    function testRefiLoan_LateRepay_LenderClaimsCollateral() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        openLending.LendingView memory loan = lending.getLending(lendingId);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        // Fast forward past loan expiration
        vm.warp(loan.start + LOAN_TERM + 1);

        // Borrower tries to repay - should fail
        uint256 totalOwed = calculateOwedAtMaturity(refiBorrowAmount, INTEREST_RATE, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, totalOwed);

        // Lender2 claims collateral
        vm.prank(lender2);
        lending.claimCollateral(lendingId);

        // Verify loan finished
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after claim");

        // Lender2 receives collateral
        assertEq(
            supplyToken.balanceOf(lender2),
            lender2SupplyBefore + SUPPLY_AMOUNT,
            "Lender2 should have received collateral"
        );

        // Lender2 is down their refi amount (they provided funds, never got paid back)
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore,
            "Lender2 borrow balance unchanged (refi funds went to lender1)"
        );

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    // =========================================================================
    // TEST: Partial repay on refinanced loan, then late
    // =========================================================================
    function testRefiLoan_PartialRepayThenLate_LenderGetsCollateralAndPartialRepay() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        openLending.LendingView memory loan = lending.getLending(lendingId);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        // Partial repayment
        uint256 partialRepayment = 20e18;
        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepayment);

        // Check repaidDebt updated
        openLending.LendingView memory loanMid = lending.getLending(lendingId);
        assertEq(loanMid.repaidDebt, partialRepayment, "Repaid debt should match partial payment");

        // Fast forward past expiration
        vm.warp(loan.start + LOAN_TERM + 1);

        // Lender2 claims
        vm.prank(lender2);
        lending.claimCollateral(lendingId);

        // Lender2 gets collateral + partial repayment
        assertEq(
            supplyToken.balanceOf(lender2),
            lender2SupplyBefore + SUPPLY_AMOUNT,
            "Lender2 should have received collateral"
        );

        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore + partialRepayment,
            "Lender2 should have received partial repayment"
        );

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    // =========================================================================
    // TEST: Multiple partial repayments on refinanced loan
    // =========================================================================
    function testRefiLoan_MultiplePartialRepayments() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        uint256 totalOwed = calculateOwedAtMaturity(refiBorrowAmount, INTEREST_RATE, LOAN_TERM);

        // First partial payment
        uint256 payment1 = 10e18;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, payment1);

        openLending.LendingView memory loan1 = lending.getLending(lendingId);
        assertEq(loan1.repaidDebt, payment1, "First partial payment tracked");
        assertFalse(loan1.finished, "Loan not finished after partial");

        // Second partial payment
        uint256 payment2 = 15e18;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, payment2);

        openLending.LendingView memory loan2 = lending.getLending(lendingId);
        assertEq(loan2.repaidDebt, payment1 + payment2, "Both payments tracked");
        assertFalse(loan2.finished, "Loan still not finished");

        // Final payment (remainder)
        uint256 remaining = totalOwed - payment1 - payment2;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, remaining);

        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after full payment");

        // Verify lender2 received full amount
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore + totalOwed,
            "Lender2 should have received total owed"
        );

        // Borrower got collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should have received collateral"
        );
    }

    // =========================================================================
    // TEST: Verify interest calculation correct on refinanced loan
    // =========================================================================
    function testRefiLoan_InterestCalculation() public {
        // After refi, the borrow amount is what was owed to lender1
        uint256 originalOwed = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        // Original: 50e18 at 10% for 30 days
        // interest = 50e18 * 30 days * 1e8 / (1e9 * 365 days) = 410958904109589 (approx 0.41e18)
        uint256 expectedOriginalInterest = (BORROW_AMOUNT * uint256(LOAN_TERM) * uint256(INTEREST_RATE)) / (1e9 * 365 days);
        assertEq(originalOwed, BORROW_AMOUNT + expectedOriginalInterest, "Original owed calculation");

        // After refi, new loan is for originalOwed amount
        // New interest on that amount for another LOAN_TERM
        uint256 refiOwed = calculateOwedAtMaturity(originalOwed, INTEREST_RATE, LOAN_TERM);
        uint256 expectedRefiInterest = (originalOwed * uint256(LOAN_TERM) * uint256(INTEREST_RATE)) / (1e9 * 365 days);
        assertEq(refiOwed, originalOwed + expectedRefiInterest, "Refi owed calculation");

        // Total interest across both loans should compound
        uint256 totalInterest = (refiOwed - BORROW_AMOUNT);
        assertGt(totalInterest, expectedOriginalInterest * 2, "Interest should compound, not just double");
    }

    // =========================================================================
    // TEST: Refinanced loan state is correct
    // =========================================================================
    function testRefiLoan_StateCorrect() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Core state
        assertEq(loan.lender, lender2, "Lender should be lender2");
        assertEq(loan.borrower, borrower, "Borrower unchanged");
        assertEq(loan.borrowAmount, refiBorrowAmount, "Borrow amount is refi amount");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT, "Supply unchanged (no pull)");
        assertEq(loan.rate, INTEREST_RATE, "Rate unchanged");
        assertEq(loan.term, LOAN_TERM, "Term unchanged");
        assertTrue(loan.active, "Still active");
        assertFalse(loan.finished, "Not finished");
        assertFalse(loan.cancelled, "Not cancelled");
        assertEq(loan.repaidDebt, 0, "Repaid debt reset to 0");
        assertEq(loan.gracePeriod, 0, "Grace period reset to 0");
        assertEq(loan.liquidator, address(0), "No liquidator");
    }

    // =========================================================================
    // TEST: Double refi then repay
    // =========================================================================
    function testDoubleRefi_ThenRepay() public {
        (uint256 lendingId, uint256 refiBorrowAmount) = setupRefinancedLoan();

        // Now refi again: lender2 -> lender1 (lender1 comes back as new lender)
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        uint256 owedToLender2 = calculateOwedAtMaturity(refiBorrowAmount, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender1);
        (uint256 refi2Offer, uint256 refi2Nonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            false,
            0,
            0,
            0
        );

        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refi2Offer, refi2Nonce);

        // Verify lender2 got paid
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore + owedToLender2,
            "Lender2 should receive owed amount"
        );

        // Now loan is with lender1 again
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.lender, lender1, "Lender should be back to lender1");
        assertEq(loan.borrowAmount, owedToLender2, "Borrow amount is what was owed to lender2");

        // Borrower repays lender1
        uint256 finalOwed = calculateOwedAtMaturity(owedToLender2, INTEREST_RATE, LOAN_TERM);
        uint256 lender1BorrowBefore = borrowToken.balanceOf(lender1);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, finalOwed);

        // Loan finished
        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished");

        // Lender1 got paid
        assertEq(
            borrowToken.balanceOf(lender1),
            lender1BorrowBefore + finalOwed,
            "Lender1 should receive final payment"
        );

        // Borrower got collateral
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral"
        );
    }

    // =========================================================================
    // TEST: Refi with supply pulled, then repay
    // =========================================================================
    function testRefiWithSupplyPulled_ThenRepay() public {
        // Setup original loan
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE
        );

        vm.prank(lender1);
        uint256 offerNum = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNum);

        // Refi with supply pulled
        uint256 supplyPulled = 30e18;
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, supplyPulled);

        uint256 owedToLender1 = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender2);
        (uint256 refiOffer, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            false,
            0,
            0,
            SUPPLY_AMOUNT - supplyPulled
        );

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOffer, refiNonce);

        // Borrower received pulled supply
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + supplyPulled,
            "Borrower should have received pulled supply"
        );

        // Loan now has reduced collateral
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT - supplyPulled, "Collateral reduced");

        // Repay the refi'd loan
        uint256 totalOwed = calculateOwedAtMaturity(owedToLender1, INTEREST_RATE, LOAN_TERM);
        uint256 borrowerSupplyBeforeRepay = supplyToken.balanceOf(borrower);

        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed);

        // Borrower gets remaining collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBeforeRepay + (SUPPLY_AMOUNT - supplyPulled),
            "Borrower should get remaining collateral"
        );
    }
}
