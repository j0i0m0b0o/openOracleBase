// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "../src/OracleSwapFacility.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract TestCallback {
    uint256 public lastReportId;
    uint256 public lastPrice;
    uint256 public lastTimestamp;
    address public lastToken1;
    address public lastToken2;

    function onOracleSettle(uint256 reportId, uint256 price, uint256 timestamp, address token1, address token2)
        external
    {
        lastReportId = reportId;
        lastPrice = price;
        lastTimestamp = timestamp;
        lastToken1 = token1;
        lastToken2 = token2;
    }
}

contract SwapFacilityTest is Test {
    OpenOracle oracle;
    OracleSwapFacility swapFacility;
    MockERC20 token1;
    MockERC20 token2;
    TestCallback callbackContract;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        // Deploy contracts
        oracle = new OpenOracle();
        swapFacility = new OracleSwapFacility(address(oracle));
        callbackContract = new TestCallback();

        // Deploy mock tokens
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Mint tokens to test users
        token1.mint(alice, 1000e18);
        token2.mint(alice, 1000e18);
        token1.mint(bob, 1000e18);
        token2.mint(bob, 1000e18);

        // Give ETH to test users
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function testSwapFacilityWithFullParams() public {
        vm.startPrank(alice);

        uint256 amount1 = 5e18;
        uint256 amount2 = 5e18;
        uint256 fee = 3000; // 3 bps
        uint256 settlementTime = 120; // 2 minutes

        // Approve tokens for swap facility
        token1.approve(address(swapFacility), amount1);
        token2.approve(address(swapFacility), amount2);

        // Create swap with full parameters including callback
        uint256 reportId = swapFacility.createAndReport{value: 0.001 ether}(
            address(token1),
            address(token2),
            amount1,
            amount2,
            fee,
            settlementTime,
            true, // timeType = true (seconds)
            address(callbackContract), // callback contract
            callbackContract.onOracleSettle.selector, // callback selector
            true, // trackDisputes
            300000, // callback gas limit
            true, // keepFee
            101, // multiplier (default 101%)
            0, // disputeDelay
            amount1 // escalationHalt (set to amount1)
        );

        // Verify tokens were transferred to oracle
        assertEq(token1.balanceOf(address(oracle)), amount1);
        assertEq(token2.balanceOf(address(oracle)), amount2);
        assertEq(reportId, 1, "Report ID should be 1");

        vm.stopPrank();

        // Bob disputes to trigger a swap
        vm.warp(block.timestamp + 1); // Past dispute delay (which is 0)
        vm.startPrank(bob);

        // Dispute by swapping token1
        uint256 disputeFee = (amount1 * fee) / 1e7;
        // Since escalationHalt = amount1, we can only increase by 1
        uint256 newAmount1 = amount1 + 1;
        // Need to change price by more than 3% to be outside fee boundary
        // Original price is 1:1, so we need amount2 to be significantly different
        uint256 newAmount2 = (amount2 * 95) / 100; // 5% less, definitely outside 3% boundary

        // Approve plenty of both tokens for the dispute
        token1.approve(address(oracle), 100e18);
        token2.approve(address(oracle), 100e18);

        (bytes32 stateHash,,,,,,) = oracle.extraData(1);
        oracle.disputeAndSwap(1, address(token1), newAmount1, newAmount2, amount2, stateHash);

        vm.stopPrank();

        // Settle and verify callback
        vm.warp(block.timestamp + settlementTime);
        oracle.settle(reportId);

        // Check callback was executed
        assertEq(callbackContract.lastReportId(), reportId);
        assertTrue(callbackContract.lastPrice() > 0);
        assertEq(callbackContract.lastToken1(), address(token1));
        assertEq(callbackContract.lastToken2(), address(token2));

        // Verify Alice got her expected tokens back
        // She should have received 2 * amount1 + fee from the token1 swap
        uint256 expectedToken1 = 2 * amount1 + disputeFee;
        assertEq(token1.balanceOf(alice), 1000e18 - amount1 + expectedToken1);
        assertEq(token2.balanceOf(alice), 1000e18 - amount2); // No token2 back since it was swapped
    }

    function testSwapFacilityWithSimpleParams() public {
        vm.startPrank(alice);

        uint256 amount1 = 5e18;
        uint256 amount2 = 5e18;
        uint256 fee = 3000; // 3 bps
        uint256 settlementTime = 120; // 2 minutes

        // Approve tokens for swap facility
        token1.approve(address(swapFacility), amount1);
        token2.approve(address(swapFacility), amount2);

        // Create swap with simple parameters (no callback)
        uint256 reportId = swapFacility.createAndReport{value: 0.001 ether}(
            address(token1), address(token2), amount1, amount2, fee, settlementTime
        );

        // Verify tokens were transferred to oracle
        assertEq(token1.balanceOf(address(oracle)), amount1);
        assertEq(token2.balanceOf(address(oracle)), amount2);
        assertEq(reportId, 1, "Report ID should be 1");

        vm.stopPrank();

        // Bob disputes to trigger a swap
        vm.warp(block.timestamp + 1); // Past dispute delay (which is 0)
        vm.startPrank(bob);

        // Dispute by swapping token1
        uint256 disputeFee = (amount1 * fee) / 1e7;
        // Since escalationHalt = amount1, we can only increase by 1
        uint256 newAmount1 = amount1 + 1;
        // Need to change price by more than 3% to be outside fee boundary
        // Original price is 1:1, so we need amount2 to be significantly different
        uint256 newAmount2 = (amount2 * 95) / 100; // 5% less, definitely outside 3% boundary

        // Approve plenty of both tokens for the dispute
        token1.approve(address(oracle), 100e18);
        token2.approve(address(oracle), 100e18);

        (bytes32 stateHash,,,,,,) = oracle.extraData(1);
        oracle.disputeAndSwap(1, address(token1), newAmount1, newAmount2, amount2, stateHash);

        vm.stopPrank();

        // Settle
        vm.warp(block.timestamp + settlementTime);
        oracle.settle(reportId);

        // Verify no callback was executed (since we didn't set one)
        assertEq(callbackContract.lastReportId(), 0);

        // Verify Alice got her expected tokens back
        // She should have received 2 * amount1 + fee from the token1 swap
        uint256 expectedToken1 = 2 * amount1 + disputeFee;
        assertEq(token1.balanceOf(alice), 1000e18 - amount1 + expectedToken1);
        assertEq(token2.balanceOf(alice), 1000e18 - amount2); // No token2 back since it was swapped
    }
}
