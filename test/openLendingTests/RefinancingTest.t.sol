// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLending_FIRST_DRAFT.sol";
import "../../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract RefinancingTest is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal lender3 = address(0x4);
    address internal liquidator = address(0x5);
    address internal settler = address(0x6);

    // Unrelated funds
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Loan parameters
    uint256 constant SUPPLY_AMOUNT = 100e18;
    uint256 constant BORROW_AMOUNT = 70e18;
    uint48 constant LOAN_TERM = 30 days;
    uint32 constant INTEREST_RATE = 1e8; // 10% annual
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint256 constant STAKE = 100; // 1%
    uint256 constant OFFER_EXPIRATION = 1 hours;

    // Oracle parameters
    uint256 constant ORACLE_EXACT_TOKEN1 = 10e18;
    uint256 constant ORACLE_SETTLEMENT_TIME = 300;

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        supplyToken = new MockERC20("Supply", "SUP");
        borrowToken = new MockERC20("Borrow", "BOR");

        // Fund accounts
        supplyToken.transfer(borrower, 10000e18);
        borrowToken.transfer(borrower, 10000e18);
        borrowToken.transfer(lender1, 10000e18);
        borrowToken.transfer(lender2, 10000e18);
        borrowToken.transfer(lender3, 10000e18);
        supplyToken.transfer(liquidator, 10000e18);
        borrowToken.transfer(liquidator, 10000e18);

        // Deposit unrelated funds
        supplyToken.transfer(address(lending), UNRELATED_SUPPLY);
        borrowToken.transfer(address(lending), UNRELATED_BORROW);

        // Approvals
        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(borrower);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.prank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.prank(lender3);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(liquidator);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(liquidator);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        borrowToken.approve(address(oracle), type(uint256).max);

        // Lender2 needs oracle approval for refi offer submissions (oracle pulls tokens)
        vm.prank(lender2);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(lender2);
        borrowToken.approve(address(oracle), type(uint256).max);

        vm.deal(liquidator, 10 ether);
    }

    // Helper: Create and activate a loan
    function setupActiveLoan() internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + OFFER_EXPIRATION),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE
        );

        vm.prank(lender1);
        uint256 offerNum = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNum);
    }

    // Helper: Calculate total owed at maturity
    function totalOwedAtMaturity(uint256 amount, uint256 rate, uint256 term) internal pure returns (uint256) {
        uint256 year = 365 days;
        uint256 interest = amount * term * rate / (1e9 * year);
        return amount + interest;
    }

    // =========================================================================
    // BASIC REFI FLOW
    // =========================================================================

    function testRefi_BasicFlow() public {
        uint256 lendingId = setupActiveLoan();

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 lender1Before = borrowToken.balanceOf(lender1);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);

        // Calculate what lender1 is owed
        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        // Borrower sets refi params (no extra demand, no supply pull)
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Lender2 offers refi
        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE + 1e7, // slightly higher rate
            true,
            0, // repaidDebt
            0, // extraDemanded
            0  // minSupplyPostRefi
        );

        assertEq(refiNonce, 1, "First refi nonce should be 1");
        assertEq(refiOfferNum, 1, "First refi offer should be 1");

        // Borrower accepts refi
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        // Verify lender1 got paid
        uint256 lender1After = borrowToken.balanceOf(lender1);
        assertEq(lender1After, lender1Before + owedToLender1, "Lender1 should receive full owed amount");

        // Verify loan state updated
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertEq(loanAfter.lender, lender2, "New lender should be lender2");
        assertEq(loanAfter.borrowAmount, owedToLender1, "New borrow amount should equal what was owed");
        assertEq(loanAfter.rate, INTEREST_RATE + 1e7, "Rate should be updated");
        assertEq(loanAfter.start, block.timestamp, "Start should be reset");
        assertEq(loanAfter.repaidDebt, 0, "Repaid debt should be reset");
        assertEq(loanAfter.gracePeriod, 0, "Grace period should be reset");

        // Borrower should NOT have received extra (no extraDemanded)
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore, "Borrower borrow balance unchanged");

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY + SUPPLY_AMOUNT, "Supply funds correct");
    }

    function testRefi_WithExtraDemanded() public {
        uint256 lendingId = setupActiveLoan();

        uint256 extraDemanded = 10e18;
        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);
        uint256 totalRefiAmount = owedToLender1 + extraDemanded;

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);

        // Set refi params with extra demand
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, extraDemanded, 0);

        // Lender2 offers refi (must provide owedToLender1 + extraDemanded)
        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            true,
            0,
            extraDemanded,
            0
        );

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        // Borrower should have received extraDemanded
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore + extraDemanded,
            "Borrower should receive extra demanded"
        );

        // New loan amount should be total
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.borrowAmount, totalRefiAmount, "New borrow amount should include extra");
    }

    function testRefi_WithSupplyPulled() public {
        uint256 lendingId = setupActiveLoan();

        uint256 supplyPulled = 20e18;
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Set refi params with supply pull
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, supplyPulled);

        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        // Lender2 offers refi
        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            true,
            0,
            0,
            SUPPLY_AMOUNT - supplyPulled // minSupplyPostRefi
        );

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        // Borrower should have received supplyPulled
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + supplyPulled,
            "Borrower should receive pulled supply"
        );

        // Loan supply reduced
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT - supplyPulled, "Supply should be reduced");
    }

    // =========================================================================
    // MULTIPLE REFI CYCLES
    // =========================================================================

    function testRefi_MultipleCycles() public {
        uint256 lendingId = setupActiveLoan();

        // --- REFI 1: lender1 -> lender2 ---
        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refi1Offer, uint256 refi1Nonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        assertEq(refi1Nonce, 1, "First refi nonce");

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refi1Offer, refi1Nonce);

        openLending.LendingView memory loanAfterRefi1 = lending.getLending(lendingId);
        assertEq(loanAfterRefi1.lender, lender2, "Lender should be lender2");
        assertEq(loanAfterRefi1.borrowAmount, owedToLender1, "Borrow amount after refi1");

        // --- REFI 2: lender2 -> lender3 ---
        vm.warp(block.timestamp + 10 days); // Some time passes

        uint256 owedToLender2 = totalOwedAtMaturity(owedToLender1, INTEREST_RATE, LOAN_TERM);
        uint256 lender2Before = borrowToken.balanceOf(lender2);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender3);
        (uint256 refi2Offer, uint256 refi2Nonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        assertEq(refi2Nonce, 2, "Second refi nonce");

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refi2Offer, refi2Nonce);

        // Lender2 should have been paid
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2Before + owedToLender2,
            "Lender2 should receive full owed"
        );

        openLending.LendingView memory loanAfterRefi2 = lending.getLending(lendingId);
        assertEq(loanAfterRefi2.lender, lender3, "Lender should be lender3");
        assertEq(loanAfterRefi2.borrowAmount, owedToLender2, "Borrow amount after refi2");

        // Verify nonce incremented
        openLending.RefiParams memory refiParams = lending.getRefiParams(lendingId);
        assertFalse(refiParams.set, "Refi params should be reset");
    }

    // =========================================================================
    // REFI PARAMS RESTRICTIONS
    // =========================================================================

    function testRefi_CannotOfferIfParamsNotSet() public {
        uint256 lendingId = setupActiveLoan();

        // Try to offer refi without params set
        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "refi params not set"));
        lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);
    }

    function testRefi_CannotSetParamsTwice() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Try to set again
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "params already set"));
        lending.changeRefiParams(lendingId, 10e18, 0);
    }

    function testRefi_ParamsResetAfterAccept() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 5e18, 0);

        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 5e18, 0);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        // Params should be reset
        openLending.RefiParams memory params = lending.getRefiParams(lendingId);
        assertFalse(params.set, "Params should not be set after accept");
        assertEq(params.extraDemanded, 0, "Extra demanded should be 0");
        assertEq(params.supplyPulled, 0, "Supply pulled should be 0");

        // Can set params again for next refi
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        openLending.RefiParams memory paramsAfter = lending.getRefiParams(lendingId);
        assertTrue(paramsAfter.set, "Should be able to set params again");
    }

    // =========================================================================
    // REFI OFFER CANCELLATION
    // =========================================================================

    function testRefi_LenderCanCancelAfter60s() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        uint256 lender2Before = borrowToken.balanceOf(lender2);
        uint256 owedToLender1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        uint256 lender2AfterOffer = borrowToken.balanceOf(lender2);
        assertEq(lender2AfterOffer, lender2Before - owedToLender1, "Lender2 should have deposited");

        vm.warp(block.timestamp + 60);

        vm.prank(lender2);
        lending.cancelRefiBorrowOffer(lendingId, refiNonce, refiOfferNum);

        assertEq(borrowToken.balanceOf(lender2), lender2Before, "Lender2 should get funds back");
    }

    function testRefi_CannotCancelBefore60s() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        vm.warp(block.timestamp + 59);

        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "cancel too soon"));
        lending.cancelRefiBorrowOffer(lendingId, refiNonce, refiOfferNum);
    }

    function testRefi_CannotCancelChosenOffer() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        vm.warp(block.timestamp + 60);

        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "chosen"));
        lending.cancelRefiBorrowOffer(lendingId, refiNonce, refiOfferNum);
    }

    function testRefi_CanCancelOldNonceOffersAfterRefi() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Lender2 and Lender3 both offer refi at nonce 1
        vm.prank(lender2);
        (uint256 offer2, uint256 nonce1) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        vm.prank(lender3);
        (uint256 offer3, ) = lending.offerRefiBorrow(lendingId, INTEREST_RATE + 1e7, true, 0, 0, 0);

        // Accept lender2's offer
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, offer2, nonce1);

        vm.warp(block.timestamp + 60);

        // Lender3 can still cancel their old offer from nonce 1
        uint256 lender3Before = borrowToken.balanceOf(lender3);
        vm.prank(lender3);
        lending.cancelRefiBorrowOffer(lendingId, nonce1, offer3);

        assertGt(borrowToken.balanceOf(lender3), lender3Before, "Lender3 should get refund");
    }

    // =========================================================================
    // ACCEPT RESTRICTIONS
    // =========================================================================

    function testRefi_CannotAcceptAfterFinished() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        // Borrower repays full debt to finish loan
        uint256 owed = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);
        vm.prank(borrower);
        lending.repayDebt(lendingId, owed);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "Loan should be finished");

        // Try to accept refi
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "lendingId finished"));
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);
    }

    function testRefi_CannotDoubleAcceptSameNonce() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Two offers at same nonce
        vm.prank(lender2);
        (uint256 offer1, uint256 nonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        vm.prank(lender3);
        (uint256 offer2, ) = lending.offerRefiBorrow(lendingId, INTEREST_RATE + 1e7, true, 0, 0, 0);

        // Accept first offer
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, offer1, nonce);

        // Try to accept second offer with same nonce
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "refi nonce already accepted"));
        lending.acceptRefiOffer(lendingId, offer2, nonce);
    }

    function testRefi_RepaidDebtMismatchVoidsOffer() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        // Lender2 makes offer when repaidDebt = 0
        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        // Borrower partially repays
        vm.prank(borrower);
        lending.repayDebt(lendingId, 10e18);

        // Now repaidDebt != 0, so the offer is stale
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "repaid debt changed"));
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);
    }

    function testRefi_CannotAcceptDuringLiquidation() public {
        uint256 lendingId = setupActiveLoan();

        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Start liquidation
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            8e18, // price that would liquidate
            BORROW_AMOUNT,
            loan.start
        );

        // Try to accept refi during liquidation
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "lendingId in liquidation"));
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);
    }

    function testRefi_CannotAcceptExpired() public {
        uint256 lendingId = setupActiveLoan();

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        // Warp past maturity
        vm.warp(block.timestamp + LOAN_TERM + 1);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "expired"));
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);
    }

    // =========================================================================
    // GRACE PERIOD WITH REFI
    // =========================================================================

    function testRefi_CanAcceptDuringGracePeriod() public {
        uint256 lendingId = setupActiveLoan();

        // Warp to near maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Start liquidation that will fail (safe price)
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12e18, // safe price
            BORROW_AMOUNT,
            loan.start
        );

        uint256 reportId = oracle.nextReportId() - 1;

        // Settle
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Grace period should be set
        openLending.LendingView memory loanAfterLiq = lending.getLending(lendingId);
        assertGt(loanAfterLiq.gracePeriod, 0, "Grace period should be set");

        // Warp into grace period (past original maturity)
        vm.warp(loanAfterLiq.start + loanAfterLiq.term + 100);

        // Set refi params and accept refi during grace
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(
            lendingId,
            INTEREST_RATE,
            true,
            0,
            0,
            loanAfterLiq.supplyAmount // minSupplyPostRefi
        );

        // Should succeed during grace
        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        openLending.LendingView memory loanAfterRefi = lending.getLending(lendingId);
        assertEq(loanAfterRefi.lender, lender2, "Refi should succeed during grace");
        assertEq(loanAfterRefi.gracePeriod, 0, "Grace period reset after refi");
    }

    // =========================================================================
    // LIQUIDATION ON REFINANCED DEBT
    // =========================================================================

    function testRefi_LiquidationWorksAfterRefi() public {
        uint256 lendingId = setupActiveLoan();

        // Refi to lender2
        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 refiOfferNum, uint256 refiNonce) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNum, refiNonce);

        openLending.LendingView memory loanAfterRefi = lending.getLending(lendingId);
        assertEq(loanAfterRefi.lender, lender2, "Lender should be lender2");

        // Wait some time
        vm.warp(block.timestamp + 10 days);

        // Liquidate the refinanced loan
        vm.prank(liquidator);
        lending.liquidate{value: 0.1 ether}(
            lendingId,
            loanAfterRefi.supplyAmount,
            0,
            8e18, // liquidating price
            loanAfterRefi.borrowAmount,
            loanAfterRefi.start
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after liquidation");
    }

    // =========================================================================
    // ACCOUNTING VERIFICATION
    // =========================================================================

    function testRefi_AccountingAcrossMultipleCycles() public {
        uint256 lendingId = setupActiveLoan();

        uint256 lender1InitialBorrow = borrowToken.balanceOf(lender1);
        uint256 lender2InitialBorrow = borrowToken.balanceOf(lender2);

        // REFI 1
        uint256 owedCycle1 = totalOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender2);
        (uint256 offer1, uint256 nonce1) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        uint256 lender2AfterOffer1 = borrowToken.balanceOf(lender2);
        assertEq(lender2AfterOffer1, lender2InitialBorrow - owedCycle1, "Lender2 deposited owedCycle1");

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, offer1, nonce1);

        assertEq(borrowToken.balanceOf(lender1), lender1InitialBorrow + owedCycle1, "Lender1 received owedCycle1");

        // REFI 2
        uint256 owedCycle2 = totalOwedAtMaturity(owedCycle1, INTEREST_RATE, LOAN_TERM);

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 0, 0);

        vm.prank(lender3);
        (uint256 offer2, uint256 nonce2) = lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 0, 0);

        uint256 lender3InitialBorrow = borrowToken.balanceOf(lender3);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, offer2, nonce2);

        // Lender2 (prev lender) gets owedCycle2
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2AfterOffer1 + owedCycle2,
            "Lender2 received owedCycle2 as prev lender"
        );

        // Final loan state
        openLending.LendingView memory finalLoan = lending.getLending(lendingId);
        assertEq(finalLoan.borrowAmount, owedCycle2, "Final borrow amount is owedCycle2");
        assertEq(finalLoan.lender, lender3, "Final lender is lender3");

        // Unrelated funds untouched throughout
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY + SUPPLY_AMOUNT, "Supply unchanged");

        // Contract borrow balance: After refi, lender3's deposit went directly to lender2 (prev lender).
        // With extraDemanded=0, no borrow tokens stay in contract from the refi.
        // So contract should just have UNRELATED_BORROW.
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Borrow = unrelated only (refi deposits went to prev lenders)"
        );
    }

    // =========================================================================
    // ORIGINAL OFFER CANCELLATION AFTER REFI
    // =========================================================================

    function testRefi_CanCancelOriginalOfferAfterLoanActive() public {
        // Create borrow request
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + OFFER_EXPIRATION),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE
        );

        // Multiple lenders offer
        vm.prank(lender1);
        uint256 offer1 = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.prank(lender2);
        uint256 offer2 = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE + 1e7, true);

        // Accept lender1's offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offer1);

        vm.warp(block.timestamp + 60);

        // Lender2 can cancel their original (non-refi) offer even though loan is active
        uint256 lender2Before = borrowToken.balanceOf(lender2);
        vm.prank(lender2);
        lending.cancelBorrowOffer(lendingId, offer2);

        assertEq(borrowToken.balanceOf(lender2), lender2Before + BORROW_AMOUNT, "Lender2 gets refund");
    }
}
