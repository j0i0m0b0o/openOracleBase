// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ToxicAirlock {
    address public immutable beneficiary;
    using SafeERC20 for IERC20;

    constructor(address _beneficiary) {
        beneficiary = _beneficiary;
    }

    function sweep(address token) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(beneficiary, bal);
        }
    }
}
