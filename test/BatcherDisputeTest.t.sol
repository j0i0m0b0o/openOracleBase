// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "../src/OpenOracleBatcher.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

contract OracleStateHashBatcherDisputeTest is Test {
    OpenOracle oracle;
    openOracleBatcher batcher;
    MockERC20 token1;
    MockERC20 token2;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        oracle = new OpenOracle();
        batcher = new openOracleBatcher(address(oracle));
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Fund accounts
        token1.transfer(alice, 100 * 10 ** 18);
        token1.transfer(bob, 100 * 10 ** 18);
        token2.transfer(alice, 100000 * 10 ** 18);
        token2.transfer(bob, 100000 * 10 ** 18);

        // Give ETH
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        // Approve oracle
        vm.prank(alice);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        token2.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token2.approve(address(oracle), type(uint256).max);

        // Also approve batcher for alice since batcher needs to transfer tokens for disputes
        vm.prank(alice);
        token1.approve(address(batcher), type(uint256).max);
        vm.prank(alice);
        token2.approve(address(batcher), type(uint256).max);
    }

    function testBatcherDispute() public {
        console.log("=== Testing Batcher Dispute ===");

        // 1. Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: 3000,
                multiplier: 110,
                settlementTime: 300,
                escalationHalt: 10e18,
                disputeDelay: 5,
                protocolFee: 1000,
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        console.log("Created report ID:", reportId);

        // 2. Get stateHash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        console.log("StateHash obtained");

        // 3. Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);
        console.log("Initial report submitted");

        // 4. Wait and dispute using batcher
        vm.warp(block.timestamp + 6);

        // Create dispute data for batcher
        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0].reportId = reportId;
        disputes[0].tokenToSwap = address(token1);
        disputes[0].newAmount1 = 1.1e18; // 1.1x multiplier
        disputes[0].newAmount2 = 2100e18;
        disputes[0].amt2Expected = 2000e18;
        disputes[0].stateHash = stateHash;

        // Calculate batch amounts needed for dispute
        // Need enough tokens to cover the dispute requirements
        // For token1: need 1e18 (old) + 1.1e18 (new) + fees
        uint256 fee = (1e18 * 3000) / 1e7; // 0.003e18
        uint256 protocolFee = (1e18 * 1000) / 1e7; // 0.001e18
        uint256 batchAmount1 = 1e18 + 1.1e18 + fee + protocolFee;
        uint256 batchAmount2 = 100e18; // Extra token2 for the swap difference

        vm.prank(alice);
        batcher.disputeReports(disputes, batchAmount1, batchAmount2);
        console.log("Dispute submitted through batcher");

        // 5. Settle
        vm.warp(block.timestamp + 300);
        (uint256 finalPrice, uint256 settlementTime) = oracle.settle(reportId);
        console.log("Settled at price:", finalPrice / 1e18);
        console.log("Settlement time:", settlementTime);

        console.log("[PASS] Batcher dispute lifecycle completed!");
    }

    receive() external payable {}
}
