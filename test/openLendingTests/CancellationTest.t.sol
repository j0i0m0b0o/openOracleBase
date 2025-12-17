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

contract CancellationTest is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal randomUser = address(0x4);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Loan parameters
    uint256 constant SUPPLY_AMOUNT = 100e18;
    uint256 constant BORROW_AMOUNT = 70e18;
    uint48 constant LOAN_TERM = 30 days;
    uint32 constant INTEREST_RATE = 1e8; // 10%
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint256 constant STAKE = 100; // 1%
    uint256 constant OFFER_EXPIRATION = 1 hours;

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        supplyToken = new MockERC20("Supply", "SUP");
        borrowToken = new MockERC20("Borrow", "BOR");

        // Fund accounts
        supplyToken.transfer(borrower, 1000e18);
        borrowToken.transfer(lender1, 1000e18);
        borrowToken.transfer(lender2, 1000e18);

        // Deposit unrelated funds to contract
        supplyToken.transfer(address(lending), UNRELATED_SUPPLY);
        borrowToken.transfer(address(lending), UNRELATED_BORROW);

        // Approvals
        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);

        vm.prank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);

        vm.prank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);
    }

    // Helper to create a borrow request
    function createBorrowRequest() internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + OFFER_EXPIRATION),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            openLending.OracleParams(300, 100, 10)
        );
    }

    // =========================================================================
    // BORROWER CANCELLATION TESTS
    // =========================================================================

    function testBorrowerCancel_Success() public {
        uint256 lendingId = createBorrowRequest();

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Borrower gets collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral back"
        );

        // Contract balance decreased by exactly SUPPLY_AMOUNT
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore - SUPPLY_AMOUNT,
            "Contract should lose exactly SUPPLY_AMOUNT"
        );

        // Unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY,
            "Unrelated supply funds should be untouched"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Unrelated borrow funds should be untouched"
        );

        // Verify cancelled state
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertTrue(loan.cancelled, "Loan should be marked as cancelled");
    }

    function testBorrowerCancel_FailsAfterOfferAccepted() public {
        uint256 lendingId = createBorrowRequest();

        // Lender makes offer
        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // Borrower tries to cancel - should fail because loan is active
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "lendingId active"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testBorrowerCancel_FailsIfAlreadyCancelled() public {
        uint256 lendingId = createBorrowRequest();

        // First cancel succeeds
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Second cancel fails
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "lendingId cancelled"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testBorrowerCancel_FailsIfNotBorrower() public {
        uint256 lendingId = createBorrowRequest();

        // Random user tries to cancel
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowRequest(lendingId);

        // Lender tries to cancel
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testBorrowerCancel_WithPendingOffers() public {
        uint256 lendingId = createBorrowRequest();

        // Lender1 makes offer
        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Lender2 makes offer
        vm.prank(lender2);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE + 1e7, true);

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Borrower cancels even with pending offers (loan not active yet)
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Borrower gets collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral back"
        );

        // Lenders' funds are still in contract (they need to cancel their offers separately)
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW + BORROW_AMOUNT * 2,
            "Contract should still hold both lender offers"
        );
    }

    // =========================================================================
    // LENDER OFFER CANCELLATION TESTS
    // =========================================================================

    function testLenderCancel_Success() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        // Wait 60 seconds (exactly when cancel becomes allowed)
        vm.warp(block.timestamp + 60);

        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Lender gets funds back
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBorrowBefore + BORROW_AMOUNT,
            "Lender should receive borrow amount back"
        );

        // Contract balance decreased by exactly BORROW_AMOUNT
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore - BORROW_AMOUNT,
            "Contract should lose exactly BORROW_AMOUNT"
        );

        // Unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY + SUPPLY_AMOUNT,
            "Unrelated supply + borrower collateral should be intact"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Unrelated borrow funds should be untouched"
        );

        // Verify offer state
        openLending.LendingOffers memory offer = lending.getLendingOffer(lendingId, offerNumber);
        assertTrue(offer.cancelled, "Offer should be marked as cancelled");
        assertEq(offer.amount, 0, "Offer amount should be zeroed");
    }

    function testLenderCancel_FailsTooSoon() public {
        uint256 lendingId = createBorrowRequest();

        uint256 offerTime = block.timestamp;

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Try to cancel immediately (before 60 seconds)
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "cancel too soon"));
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Try at 59 seconds (should still fail)
        vm.warp(offerTime + 59);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "cancel too soon"));
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // At exactly 60 seconds should succeed (60 < 60 is false)
        vm.warp(offerTime + 60);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);
    }

    function testLenderCancel_FailsAfterOfferChosen() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts the offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        // Wait 60 seconds
        vm.warp(block.timestamp + 60);

        // Lender tries to cancel - should fail because offer was chosen
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "chosen"));
        lending.cancelBorrowOffer(lendingId, offerNumber);
    }

    function testLenderCancel_FailsIfAlreadyCancelled() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // First cancel succeeds
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Second cancel fails - amount is 0 after cancel, so "no borrow offer" error
        // (amount == 0 check comes before cancelled check in contract)
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "no borrow offer"));
        lending.cancelBorrowOffer(lendingId, offerNumber);
    }

    function testLenderCancel_FailsIfNotLender() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // Random user tries to cancel
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Different lender tries to cancel
        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Borrower tries to cancel
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowOffer(lendingId, offerNumber);
    }

    function testLenderCancel_NonExistentOffer() public {
        uint256 lendingId = createBorrowRequest();

        vm.warp(block.timestamp + 60);

        // Try to cancel offer that doesn't exist
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "msg.sender"));
        lending.cancelBorrowOffer(lendingId, 999);
    }

    // =========================================================================
    // MULTIPLE OFFERS SCENARIOS
    // =========================================================================

    function testMultipleOffers_OnlyChosenCannotCancel() public {
        uint256 lendingId = createBorrowRequest();

        // Both lenders make offers
        vm.prank(lender1);
        uint256 offer1 = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.prank(lender2);
        uint256 offer2 = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE + 1e7, true);

        // Borrower accepts lender1's offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offer1);

        vm.warp(block.timestamp + 60);

        // Lender1 cannot cancel (chosen)
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "chosen"));
        lending.cancelBorrowOffer(lendingId, offer1);

        // Lender2 CAN cancel (not chosen)
        uint256 lender2Before = borrowToken.balanceOf(lender2);
        vm.prank(lender2);
        lending.cancelBorrowOffer(lendingId, offer2);

        assertEq(
            borrowToken.balanceOf(lender2),
            lender2Before + BORROW_AMOUNT,
            "Lender2 should get funds back"
        );
    }

    function testLenderCancel_AfterBorrowerCancels() public {
        uint256 lendingId = createBorrowRequest();

        // Lender makes offer
        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower cancels
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        vm.warp(block.timestamp + 60);

        // Lender can still cancel their offer and get funds back
        uint256 lenderBefore = borrowToken.balanceOf(lender1);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);

        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBefore + BORROW_AMOUNT,
            "Lender should get funds back even after borrower cancelled"
        );
    }

    // =========================================================================
    // EDGE CASES
    // =========================================================================

    function testCannotOfferOnCancelledRequest() public {
        uint256 lendingId = createBorrowRequest();

        // Borrower cancels
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Lender tries to make offer on cancelled request
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "lendingId cancelled"));
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);
    }

    function testCannotAcceptCancelledOffer() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // Lender cancels offer
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // Borrower tries to accept cancelled offer
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "offer cancelled"));
        lending.acceptOffer(lendingId, offerNumber);
    }

    function testExactTimingAt60Seconds() public {
        uint256 lendingId = createBorrowRequest();

        uint256 offerTime = block.timestamp;

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // At 59 seconds after offer, should still fail
        vm.warp(offerTime + 59);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "cancel too soon"));
        lending.cancelBorrowOffer(lendingId, offerNumber);

        // At exactly 60 seconds, should succeed (condition is <)
        vm.warp(offerTime + 60);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId, offerNumber);
    }
}
