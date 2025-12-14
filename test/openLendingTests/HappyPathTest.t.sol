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

contract HappyPathTest is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken; // collateral token
    MockERC20 internal borrowToken; // loan token

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal settler = address(0x3);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    // Loan parameters
    uint256 constant SUPPLY_AMOUNT = 100 ether;      // 100 tokens collateral
    uint256 constant BORROW_AMOUNT = 50 ether;       // 50 tokens borrowed (50% LTV)
    uint48 constant LOAN_TERM = 30 days;             // 30 day loan
    uint32 constant INTEREST_RATE = 1e8;             // 10% annual
    uint24 constant LIQUIDATION_THRESHOLD = 8e6;     // 80%
    uint256 constant STAKE = 100;                    // 1% stake for liquidator

    function setUp() public {
        // Deploy oracle and lending
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        // Deploy tokens
        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        // Fund accounts
        supplyToken.transfer(borrower, 1000 ether);
        borrowToken.transfer(lender, 1000 ether);
        borrowToken.transfer(borrower, 1000 ether); // borrower needs borrowToken to repay

        // Give ETH for gas
        vm.deal(borrower, 10 ether);
        vm.deal(lender, 10 ether);
        vm.deal(settler, 10 ether);

        // Approvals
        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);

        vm.prank(borrower);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender);
        borrowToken.approve(address(lending), type(uint256).max);

        // Seed lending contract with unrelated funds to verify no skimming
        supplyToken.transfer(address(lending), UNRELATED_SUPPLY);
        borrowToken.transfer(address(lending), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Helper: Calculate expected interest at maturity
    // -------------------------------------------------------------------------
    function calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint256) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return principal + interest;
    }

    // -------------------------------------------------------------------------
    // Test: Full happy path - borrow, repay on time
    // -------------------------------------------------------------------------
    function testHappyPath_BorrowAndRepayOnTime() public {
        // Track initial balances
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lendingSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 lendingBorrowBefore = borrowToken.balanceOf(address(lending));

        // 1. Borrower requests a borrow
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours), // offerExpiration
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE
        );

        assertEq(lendingId, 1, "First lending ID should be 1");

        // Verify collateral transferred
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore - SUPPLY_AMOUNT,
            "Borrower should have sent collateral"
        );
        assertEq(
            supplyToken.balanceOf(address(lending)),
            lendingSupplyBefore + SUPPLY_AMOUNT,
            "Lending contract should have received collateral"
        );

        // 2. Lender offers to fill the borrow
        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(
            lendingId,
            BORROW_AMOUNT,
            INTEREST_RATE,
            false // allowAnyLiquidator
        );

        assertEq(offerNumber, 1, "First offer number should be 1");

        // Verify lender's funds transferred to contract
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBefore - BORROW_AMOUNT,
            "Lender should have sent borrow amount"
        );

        // 3. Borrower accepts offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // Verify borrower received the loan
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore + BORROW_AMOUNT,
            "Borrower should have received borrow amount"
        );

        // Verify loan state using view function
        openLending.LendingView memory loan = lending.getLending(lendingId);

        assertEq(loan.term, LOAN_TERM, "Term should match");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT, "Supply amount should match");
        assertEq(loan.borrowAmount, BORROW_AMOUNT, "Borrow amount should match");
        assertEq(loan.rate, INTEREST_RATE, "Rate should match");
        assertEq(loan.start, block.timestamp, "Start should be now");
        assertTrue(loan.active, "Loan should be active");
        assertFalse(loan.finished, "Loan should not be finished");
        assertEq(loan.borrower, borrower, "Borrower should match");
        assertEq(loan.lender, lender, "Lender should match");

        // 4. Calculate how much borrower owes at maturity
        uint256 totalOwed = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        // For 50 ether at 10% annual for 30 days:
        // interest = 50e18 * 30 days * 1e8 / (1e9 * 365 days)
        uint256 expectedInterest = (BORROW_AMOUNT * uint256(LOAN_TERM) * uint256(INTEREST_RATE)) / (1e9 * 365 days);
        assertEq(totalOwed, BORROW_AMOUNT + expectedInterest, "Total owed calculation mismatch");

        // 5. Fast forward to mid-loan and repay
        vm.warp(block.timestamp + 15 days);

        // Track balances before repayment
        uint256 borrowerBorrowBeforeRepay = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBeforeRepay = supplyToken.balanceOf(borrower);
        uint256 lenderBorrowBeforeRepay = borrowToken.balanceOf(lender);

        // Borrower repays full amount (principal + interest at maturity, not pro-rated!)
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed);

        // 6. Verify loan is finished
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after full repayment");

        // 7. Verify token movements
        // Borrower paid totalOwed
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBeforeRepay - totalOwed,
            "Borrower should have paid total owed"
        );

        // Borrower got collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBeforeRepay + SUPPLY_AMOUNT,
            "Borrower should have received collateral back"
        );

        // Lender received full payment
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBeforeRepay + totalOwed,
            "Lender should have received total owed"
        );

        // 8. Verify unrelated funds are untouched
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY,
            "Unrelated supply tokens should be untouched"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Unrelated borrow tokens should be untouched"
        );
    }

    // -------------------------------------------------------------------------
    // Test: Borrower tries to repay too late - lender claims collateral
    // -------------------------------------------------------------------------
    function testLateRepay_LenderClaimsCollateral() public {
        // Track initial balances
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);

        // 1. Setup loan (same as happy path)
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

        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(
            lendingId,
            BORROW_AMOUNT,
            INTEREST_RATE,
            false
        );

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // 2. Fast forward past loan expiration
        vm.warp(block.timestamp + LOAN_TERM + 1);

        // 3. Borrower tries to repay - should fail (expired)
        uint256 totalOwed = calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, totalOwed);

        // 4. Lender claims collateral
        lending.claimCollateral(lendingId);

        // 5. Verify loan is finished
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "Loan should be finished after claim");

        // 6. Verify lender received collateral (no repaid debt since borrower didn't repay anything)
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + SUPPLY_AMOUNT,
            "Lender should have received collateral"
        );

        // Lender is down the borrow amount (they gave the loan, never got paid back)
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBefore - BORROW_AMOUNT,
            "Lender should still be down the borrow amount"
        );

        // 7. Verify unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY,
            "Unrelated supply tokens should be untouched"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Unrelated borrow tokens should be untouched"
        );
    }

    // -------------------------------------------------------------------------
    // Test: Partial repayment then late - lender gets collateral + partial repayment
    // -------------------------------------------------------------------------
    function testPartialRepayThenLate_LenderGetsCollateralAndPartialRepay() public {
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);

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
            STAKE
        );

        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // Partial repayment mid-loan
        uint256 partialRepayment = 20 ether;
        vm.warp(block.timestamp + 15 days);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepayment);

        // Check repaidDebt updated
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.repaidDebt, partialRepayment, "Repaid debt should match partial payment");

        // Fast forward past expiration
        vm.warp(block.timestamp + LOAN_TERM);

        // Lender claims
        lending.claimCollateral(lendingId);

        // Lender gets collateral + partial repayment
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + SUPPLY_AMOUNT,
            "Lender should have received collateral"
        );
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBefore - BORROW_AMOUNT + partialRepayment,
            "Lender should have received partial repayment"
        );

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Test: Interest calculation verification
    // -------------------------------------------------------------------------
    function testInterestCalculation() public {
        // Test various scenarios to verify interest math

        // 10% annual for 1 year on 100 tokens = 10 tokens interest
        uint256 owed1 = calculateOwedAtMaturity(100 ether, 1e8, 365 days);
        assertEq(owed1, 110 ether, "1 year at 10% should be 110 total");

        // 10% annual for 30 days on 100 tokens
        uint256 owed2 = calculateOwedAtMaturity(100 ether, 1e8, 30 days);
        uint256 expectedInterest30d = (100 ether * uint256(30 days) * uint256(1e8)) / (1e9 * 365 days);
        assertEq(owed2, 100 ether + expectedInterest30d, "30 days interest calculation");

        // 20% annual (2e8) for 6 months on 50 tokens
        uint256 owed3 = calculateOwedAtMaturity(50 ether, 2e8, 182 days);
        uint256 expectedInterest6mo = (50 ether * uint256(182 days) * uint256(2e8)) / (1e9 * 365 days);
        assertEq(owed3, 50 ether + expectedInterest6mo, "6 months at 20% calculation");
    }

    // -------------------------------------------------------------------------
    // Test: Cannot borrow 0
    // -------------------------------------------------------------------------
    function testCannotBorrow0() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "cant borrow 0"));
        lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            0, // amountDemanded = 0
            STAKE
        );
    }

    // -------------------------------------------------------------------------
    // Test: Cannot supply 0
    // -------------------------------------------------------------------------
    function testCannotSupply0() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "cant supply 0"));
        lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            0, // supplyAmount = 0
            BORROW_AMOUNT,
            STAKE
        );
    }

    // -------------------------------------------------------------------------
    // Test: Verify offer data via view function
    // -------------------------------------------------------------------------
    function testLendingOfferViewFunction() public {
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

        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Use view function to check offer data
        openLending.LendingOffers memory offer = lending.getLendingOffer(lendingId, offerNumber);

        assertEq(offer.lender, lender, "Offer lender should match");
        assertEq(offer.amount, BORROW_AMOUNT, "Offer amount should match");
        assertEq(offer.rate, INTEREST_RATE, "Offer rate should match");
        assertTrue(offer.allowAnyLiquidator, "allowAnyLiquidator should be true");
        assertFalse(offer.cancelled, "Offer should not be cancelled");
        assertFalse(offer.chosen, "Offer should not be chosen yet");
    }
}
