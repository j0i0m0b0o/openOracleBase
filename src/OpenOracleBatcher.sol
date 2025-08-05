// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

contract OpenOracleBatcher is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error EthTransferFailed();

    /* ─── immutables & constants ────────────────────────────── */
    IOpenOracle public immutable oracle;

    /* ─── constructor ──────────────────────────────────────── */
    constructor(address oracleAddress) {
        require(oracleAddress != address(0), "oracle 0");
        oracle = IOpenOracle(oracleAddress);
    }

    struct InitialReportData {
        uint256 reportId;
        uint256 amount1;
        uint256 amount2;
        bytes32 stateHash;
    }

    //note: the first function input "reports" must ALL BE THE SAME TOKEN PAIR. technically, you can do both WETH/USDC and USDC/WETH reports for token1/token2 combinations in one call.
    function submitInitialReports(InitialReportData[] calldata reports, uint256 batchAmount1, uint256 batchAmount2)
        external
        nonReentrant
    {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        // Get token addresses from 0th report
        address token1 = oracle.reportMeta(reports[0].reportId).token1;
        address token2 = oracle.reportMeta(reports[0].reportId).token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), batchAmount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), batchAmount2);

        for (uint256 i = 0; i < reports.length; i++) {
            InitialReportData memory report = reports[i];
            try oracle.submitInitialReport(report.reportId, report.amount1, report.amount2, report.stateHash, sender) {
                // Success - continue to next
            } catch {
                // Failed - skip and continue
                continue;
            }
        }

        // Calculate how much was actually spent
        uint256 spent1 = (startBal1 + batchAmount1) - IERC20(token1).balanceOf(address(this));
        uint256 spent2 = (startBal2 + batchAmount2) - IERC20(token2).balanceOf(address(this));

        // Return unspent tokens
        if (spent1 < batchAmount1) {
            IERC20(token1).safeTransfer(sender, batchAmount1 - spent1);
        }
        if (spent2 < batchAmount2) {
            IERC20(token2).safeTransfer(sender, batchAmount2 - spent2);
        }

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    struct DisputeData {
        uint256 reportId;
        address tokenToSwap;
        uint256 newAmount1;
        uint256 newAmount2;
        uint256 amt2Expected;
        bytes32 stateHash;
    }

    //note: the first function input "disputes" must ALL BE THE SAME TOKEN PAIR. technically, you can do both WETH/USDC and USDC/WETH reports for token1/token2 combinations in one call.
    function disputeReports(DisputeData[] calldata disputes, uint256 batchAmount1, uint256 batchAmount2)
        external
        nonReentrant
    {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        // Get token addresses from 0th report
        address token1 = oracle.reportMeta(disputes[0].reportId).token1;
        address token2 = oracle.reportMeta(disputes[0].reportId).token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), batchAmount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), batchAmount2);

        for (uint256 i = 0; i < disputes.length; i++) {
            DisputeData memory dispute = disputes[i];
            try oracle.disputeAndSwap(
                dispute.reportId,
                dispute.tokenToSwap,
                dispute.newAmount1,
                dispute.newAmount2,
                sender,
                dispute.amt2Expected,
                dispute.stateHash
            ) {
                // Success - continue to next
            } catch {
                // Failed - skip and continue
                continue;
            }
        }

        // Calculate how much was actually spent
        uint256 spent1 = (startBal1 + batchAmount1) - IERC20(token1).balanceOf(address(this));
        uint256 spent2 = (startBal2 + batchAmount2) - IERC20(token2).balanceOf(address(this));

        // Return unspent tokens
        if (spent1 < batchAmount1) {
            IERC20(token1).safeTransfer(sender, batchAmount1 - spent1);
        }
        if (spent2 < batchAmount2) {
            IERC20(token2).safeTransfer(sender, batchAmount2 - spent2);
        }

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    struct SettleData {
        uint256 reportId;
    }

    struct SafeSettleData {
        uint256 reportId;
        bytes32 stateHash;
    }

    function settleReports(SettleData[] calldata settles) external nonReentrant {
        uint256 balanceBefore = address(this).balance;
        for (uint256 i = 0; i < settles.length; i++) {
            SettleData memory settle = settles[i];
            try oracle.settle(settle.reportId) {}
            catch {
                continue;
            }
        }
        uint256 total = address(this).balance - balanceBefore;
        (bool ok,) = payable(msg.sender).call{value: total}("");
        if (!ok) revert EthTransferFailed();
    }

    function safeSettleReports(SafeSettleData[] calldata settles) external nonReentrant {
        uint256 balanceBefore = address(this).balance;
        for (uint256 i = 0; i < settles.length; i++) {
            SafeSettleData memory settle = settles[i];
            if (oracle.extraData(settle.reportId).stateHash == settle.stateHash) {
                try oracle.settle(settle.reportId) {}
                catch {
                    continue;
                }
            } else {
                continue;
            }
        }
        uint256 total = address(this).balance - balanceBefore;
        (bool ok,) = payable(msg.sender).call{value: total}("");
        if (!ok) revert EthTransferFailed();
    }

    function requestPrices(IOpenOracle.CreateReportParams[] calldata priceRequests) external payable nonReentrant {
        for (uint256 i = 0; i < priceRequests.length; i++) {
            IOpenOracle.CreateReportParams memory req = priceRequests[i];
            oracle.createReportInstance{value: msg.value / priceRequests.length}(req);
        }

        (bool ok,) = payable(msg.sender).call{value: msg.value % priceRequests.length}("");
        if (!ok) revert EthTransferFailed();
    }

    /* -- accept ETH rewards ------------------------------------------------- */
    receive() external payable {}
}
