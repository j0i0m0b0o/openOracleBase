// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "./utils/MockERC20.sol";

// Shared base for tests that use OpenOracle with OZ-based MockERC20 tokens
abstract contract BaseTest is Test {
    OpenOracle internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    // Common setup: deploy oracle and tokens, fund users, and approve oracle
    function setUp() public virtual {
        oracle = new OpenOracle();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Fund accounts with tokens
        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        // Give ETH
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        // Approve oracle for all users
        vm.startPrank(alice);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }
}
