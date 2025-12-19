// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IERC20}      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* ------------ Oracle Fee Receiver ------------ */

contract oracleFeeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable owner;
    uint256 public immutable gameId;
    IOpenOracle public immutable oracle;
    address public token1;
    address public token2;

    constructor(address _owner, uint256 _gameId, address _oracle, address _token1, address _token2) {
        owner = _owner;
        gameId = _gameId;
        oracle = IOpenOracle(_oracle);
        token1 = _token1;
        token2 = _token2;
    }

    function sweep(address token) external nonReentrant returns(uint256) {
        if (msg.sender != owner) revert("not owner");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(msg.sender, bal);
        }

        return bal;
    }

    function collect() external nonReentrant {
        oracle.getProtocolFees(token1);
        oracle.getProtocolFees(token2);
    }
}
