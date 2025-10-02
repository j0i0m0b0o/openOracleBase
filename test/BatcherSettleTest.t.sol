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

contract OracleStateHashBatcherSettleTest is Test {
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

        // Approve
        vm.prank(alice);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        token2.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token2.approve(address(oracle), type(uint256).max);
    }

    function testBatcherSettle() public {
        console.log("=== Testing Batcher Settle ===");

        // 1. Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                protocolFeeRecipient: address(0),
                feeToken: true
            })
        );

        console.log("Created report ID:", reportId);

        // 2. Get stateHash
        (bytes32 stateHash,,,,,,,,) = oracle.extraData(reportId);
        console.log("StateHash obtained");

        // 3. Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);
        console.log("Initial report submitted");

        // 4. Wait and dispute
        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18, // 1.1x multiplier
            2100e18,
            2000e18, // amt2Expected
            stateHash
        );
        console.log("Dispute submitted");

        // 5. Settle using batcher
        vm.warp(block.timestamp + 300);

        // Create settle data
        openOracleBatcher.SettleData[] memory settles = new openOracleBatcher.SettleData[](1);
        settles[0].reportId = reportId;

        // Check ETH balances before
        uint256 callerBalanceBefore = address(this).balance;
        uint256 batcherBalanceBefore = address(batcher).balance;
        console.log("Caller ETH before:", callerBalanceBefore);
        console.log("Batcher ETH before:", batcherBalanceBefore);

        // Call settleReports - anyone can call this
        batcher.settleReports(settles);

        // Check ETH balances after
        uint256 callerBalanceAfter = address(this).balance;
        uint256 batcherBalanceAfter = address(batcher).balance;
        console.log("Caller ETH after:", callerBalanceAfter);
        console.log("Batcher ETH after:", batcherBalanceAfter);
        console.log("ETH gained:", callerBalanceAfter - callerBalanceBefore);

        // Verify settlement
        IOpenOracle.ReportStatus memory status = IOpenOracle(address(oracle)).reportStatus(reportId);
        assertTrue(status.isDistributed);
        console.log("Settled at price:", status.price / 1e18);
        console.log("Settlement time:", status.settlementTimestamp);

        console.log("[PASS] Batcher settle lifecycle completed!");
    }

    receive() external payable {}
}
