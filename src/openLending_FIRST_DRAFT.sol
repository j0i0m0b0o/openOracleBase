// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IERC20}      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* ------------ openLending v1 ------------ */
// Uses openOracle: https://openprices.gitbook.io/openoracle-docs/openoracle
// TODO: some way to let ppl grab oracle game protocol fees before settlement? just make the protocol fee sweep an internal function and should be easy
// TODO: improve grace period mechanics in context of variable settlement time (300 currently hard coded as part of the input)
// TODO: explore design space where borrower can withdraw repaid debt or excess collateral prior to end of term or refinancing via openOracle
//       how would this interact with liquidation oracle game to prevent bad outcomes for lender

contract oracleFeeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable owner;
    uint256 public immutable lendingId;
    IOpenOracle public immutable oracle;
    address public token1;
    address public token2;

    constructor(address _owner, uint256 _lendingId, address _oracle, address _token1, address _token2) {
        owner = _owner;
        lendingId = _lendingId;
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

contract openLending is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IOpenOracle public immutable oracle;

    error InvalidInput(string);

    uint256 nextLendingId = 1;

    mapping(uint256 => LendingArrangement) public lendingArrangements;
    mapping(uint256 => uint256) public reportIdToLending;
    mapping(address => mapping(address => uint256)) public tempHolding;

    constructor(IOpenOracle _oracle) {
        oracle = _oracle;
    }

    struct LendingArrangement {
        uint256 supplyAmount; // amount supplied as collateral
        uint256 borrowAmount; // amount borrowed at time of loan origination
        uint256 amountDemanded; // amount demanded by borrower
        uint256 repaidDebt; // amount of debt repaid
        uint256 refiOfferNonce; // unique identification number of refinancing round (one per new loan)

        address borrower; // borrower address
        uint48 term; // length of loan in seconds
        uint48 start; // timestamp loan began

        address lender; // lender address
        uint48 offerNumber; // lender's offer number for original borrow request
        uint48 offerExpiration; // timestamp lenders must submit offers by, for original borrow request. NOTE: IS THIS EVEN NECESSARY?

        address liquidator; // liquidator address
        uint48 liquidationStart; // timestamp where the liquidation started
        uint48 gracePeriod; // extra time to repay debt / accept refinance offer if liquidation oracle game runs past maturity

        address supplyToken; // supply token
        uint48 refiOfferNumber; // lender's offer number for refi instance
        uint32 rate; // 1e8 = 10%, annual interest rate
        uint16 stake; // 100 = 1%. stake * supplyAmount is how much liquidator must wager openOracle resolves to liquidation.

        address borrowToken; // borrow token
        uint24 liquidationThreshold; // 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
        bool cancelled; // borrow request cancelled by borrower
        bool active; // offer accepted and loan is live
        bool inLiquidation; // loan is in liquidation (oracle game is running)
        bool finished; // loan has been liquidated or repaid
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting profits 50/50

        address feeRecipient; // contract that receives protocol fees from oracle game

        RefiParams refiParams; // parameters for borrower's next refinance
        OracleParams oracleParams; // parameters for oracle game

        mapping(uint256 => LendingOffers) lendingOffers;
        mapping(uint256 => mapping(uint256 => RefiLendingOffers)) refiLendingOffers;
        mapping(uint256 => bool) refiNonceAccepted;
    }

    struct LendingOffers {
        uint256 amount; // amount offered. NOTE: IS THIS NEEDED?
        address lender; // lender address of this offer
        uint48 offerTime; // time of offer
        uint32 rate; // 1e8 = 10%, interest rate offered
        bool cancelled; // offer has been cancelled by prospective lender. must wait 60 seconds after offerTime
        bool chosen; // offer has been accepted by borrower
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting profits 50/50
    }

    struct RefiLendingOffers {
        uint256 amount; // amount of this refi offer. NOTE: IS THIS NEEDED?
        uint256 repaidDebtAtRefiOfferTime; // borrower's repaid debt at refi offer time
        uint256 extra; // extra borrow demanded by borrower in this refinancing
        address lender; // lender address of this refi offer
        uint48 refiOfferTime; // time of refi offer by prospective lender
        uint32 rate; // 1e8 = 10%, interest rate offered
        bool cancelled; // refi offer has been cancelled by prospective lender. must wait 60 seconds after refiOfferTime
        bool chosen; // refi offer has been accepted by borrower
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting remaining equity 50/50
    }

    struct RefiParams {
        uint256 extraDemanded; // extra borrow demanded by borrower on refi
        uint256 supplyPulled; //  supplyAmount pulled out by borrower on refi
        bool set; // true means RefiParams have been set, borrower can only change params once per term ahead of refi
    }

    struct OracleParams {
        uint48 settlementTime; // settlementTime of oracle game in seconds
        uint16 escalationFactor; // escalationFactor * supplyAmount = escalationHalt in oracle game, 250 => 2.5 * supplyAmount
        uint16 initialLiquidity; // fraction of supplyAmount for oracle game initial liquidity in token1, 10 = 10%.
    }

    event BorrowRequested(address indexed borrower, uint256 indexed lendingId, address supplyToken, address borrowToken, uint256 supplyAmount, uint24 liquidationThreshold, uint256 offerExpiration, uint256 stake, OracleParams oracleParams);
    event BorrowOffered(address indexed lender, uint256 indexed lendingId, uint256 amount, uint32 rate);
    event RefiBorrowOffered(address indexed lender, uint256 indexed lendingId, uint32 rate, uint256 refiNonce, uint256 refiOfferNumber);
    event BorrowRequestCancelled(address indexed borrower, uint256 indexed lendingId);
    event BorrowOfferCancelled(uint256 lendingId, uint256 offerNumber);
    event RefiBorrowOfferCancelled(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce);
    event OfferAccepted(uint256 lendingId, uint256 offerNumber);
    event RefiOfferAccepted(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce);
    event LoanLiquidationUnderway(uint256 lendingId, uint256 reportId);
    event DebtRepaid(uint256 lendingId, uint256 amount);
    event CollateralToppedOff(uint256 lendingId, uint256 amount);
    event CollateralClaimedByLender(uint256 lendingId, uint256 supplyTokenClaimed, uint256 borrowTokenClaimed);
    event RefiParamsUpdated(uint256 lendingId, uint256 extraBorrowDemanded, uint256 supplyPulled);
    event LiqFinishedUnderwater(uint256 lendingId);
    event LiqFinishedWithBuffer(uint256 lendingId);
    event LiqUnsuccessful(uint256 lendingId);

    /**
     * @notice Requests a borrow and transfers supplyAmount of supplyToken into the contract
     * @param term Length of loan in seconds
     * @param offerExpiration Timestamp lenders must submit offers by
     * @param supplyToken Supplied collateral's token address
     * @param borrowToken Borrowed token's address
     * @param liquidationThreshold 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
     * @param supplyAmount Amount supplied as collateral
     * @param amountDemanded Amount to borrow
     * @param stake 100 = 1%. stake * supplyAmount is how much liquidator must wager openOracle resolves to liquidation
     * @param oracleParams Oracle game paramters: settlementTime, escalationFactor, initialLiquidity
     * @return lendingId Unique identification number of lending instance
     */
    function requestBorrow(uint48 term, uint48 offerExpiration, address supplyToken, address borrowToken, uint24 liquidationThreshold, uint256 supplyAmount, uint256 amountDemanded, uint256 stake, OracleParams memory oracleParams) external nonReentrant returns (uint256 lendingId) {
        if (offerExpiration > block.timestamp + 60 * 60 * 24 || offerExpiration <= block.timestamp) revert InvalidInput("offerExpiration out of bounds");
        if (supplyToken == borrowToken) revert InvalidInput("supply == borrow");
        if (liquidationThreshold > 1e7 || liquidationThreshold < 7e6) revert InvalidInput("LT out of bounds");
        if (stake > 10000) revert InvalidInput("stake too high");
        if (amountDemanded == 0) revert InvalidInput("cant borrow 0");
        if (supplyAmount == 0) revert InvalidInput("cant supply 0");
        if (oracleParams.settlementTime < 120 || oracleParams.settlementTime > 60 * 60 * 4) revert InvalidInput("oracle settlementTime out of bounds");
        if (oracleParams.escalationFactor < 100 || oracleParams.escalationFactor > 1000) revert InvalidInput("oracle escalation factor out of bounds");
        if (oracleParams.initialLiquidity < 10 || oracleParams.initialLiquidity > 200) revert InvalidInput("oracle initial liquidity out of bounds");
        if (oracleParams.escalationFactor < oracleParams.initialLiquidity) revert InvalidInput("escalation factor too small");

        lendingId = nextLendingId++;

        lendingArrangements[lendingId].term = term;
        lendingArrangements[lendingId].offerExpiration = offerExpiration;
        lendingArrangements[lendingId].supplyToken = supplyToken;
        lendingArrangements[lendingId].borrowToken = borrowToken;
        lendingArrangements[lendingId].supplyAmount = supplyAmount;
        lendingArrangements[lendingId].liquidationThreshold = liquidationThreshold;
        lendingArrangements[lendingId].amountDemanded = amountDemanded;
        lendingArrangements[lendingId].stake = uint16(stake);
        lendingArrangements[lendingId].offerNumber = 1;
        lendingArrangements[lendingId].refiOfferNumber = 1;
        lendingArrangements[lendingId].refiOfferNonce = 1;

        lendingArrangements[lendingId].borrower = msg.sender;
        lendingArrangements[lendingId].oracleParams = oracleParams;

        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), supplyAmount);

        emit BorrowRequested(msg.sender, lendingId, supplyToken, borrowToken, supplyAmount, liquidationThreshold, offerExpiration, stake, oracleParams);
        return lendingId;
    }

    /**
     * @notice Cancels borrow request and returns collateral back to borrower
     * @param lendingId Unique identification number of lending instance
     */
    function cancelBorrowRequest(uint256 lendingId) external nonReentrant {
        if (lendingArrangements[lendingId].cancelled) revert InvalidInput("lendingId cancelled");
        if (lendingArrangements[lendingId].active) revert InvalidInput("lendingId active");
        if (lendingArrangements[lendingId].borrower != msg.sender) revert InvalidInput("msg.sender");

        lendingArrangements[lendingId].cancelled = true;

        IERC20(lendingArrangements[lendingId].supplyToken).safeTransfer(msg.sender, lendingArrangements[lendingId].supplyAmount);
        emit BorrowRequestCancelled(msg.sender, lendingId);

    }

    /**
     * @notice Offers a loan to borrower and transfers loan amount into the contract
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount borrower requests
     * @param rate Interest rate offered, 1e8 = 10%
     * @param allowAnyLiquidator Allows anyone to liquidate the loan and split remaining equity 50/50 with lender
     * @return offerNumber Unique identification number of loan offer
     */
    function offerBorrow(uint256 lendingId, uint256 amount, uint32 rate, bool allowAnyLiquidator) external nonReentrant returns (uint256 offerNumber) {
        if (lendingArrangements[lendingId].cancelled) revert InvalidInput("lendingId cancelled");
        if (lendingArrangements[lendingId].active) revert InvalidInput("lendingId active");
        if (lendingArrangements[lendingId].finished) revert InvalidInput("lendingId finished");
        if (msg.sender == lendingArrangements[lendingId].borrower) revert InvalidInput("lender == borrower");
        if (block.timestamp > lendingArrangements[lendingId].offerExpiration) revert InvalidInput("offer period expired");
        if (amount != lendingArrangements[lendingId].amountDemanded) revert InvalidInput("amount wrong");

        offerNumber = lendingArrangements[lendingId].offerNumber;
        address borrowToken = lendingArrangements[lendingId].borrowToken;

        lendingArrangements[lendingId].lendingOffers[offerNumber].lender = msg.sender;
        lendingArrangements[lendingId].lendingOffers[offerNumber].amount = amount;
        lendingArrangements[lendingId].lendingOffers[offerNumber].rate = rate;
        lendingArrangements[lendingId].lendingOffers[offerNumber].allowAnyLiquidator = allowAnyLiquidator;
        lendingArrangements[lendingId].lendingOffers[offerNumber].offerTime = uint48(block.timestamp);

        lendingArrangements[lendingId].offerNumber += 1;

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        emit BorrowOffered(msg.sender, lendingId, amount, rate);

        return offerNumber;
    }

    // todo: maybe prevent lenders from cancelling refi offers if too close to maturity?
    /**
     * @notice Offers a refinancing loan to borrower and transfers net refi amount demanded into the contract
     * @param lendingId Unique identification number of lending instance
     * @param rate Interest rate offered, 1e8 = 10%
     * @param allowAnyLiquidator Allows anyone to liquidate the loan and split remaining equity 50/50 with lender
     * @param repaidDebtExpected Amount borrower has already repaid in the existing loan
     * @param extraDemandedExpected Extra borrow amount borrower has requested on top of existing net loan amount
     * @param minSupplyPostRefi Minimum supplied collateral tolerated post refinancing
     * @return refiOfferNumber Unique identification number of refi loan offer
     * @return refiNonce Unique identification number of refinancing round (one per new loan)
     */
    function offerRefiBorrow(uint256 lendingId, uint32 rate, bool allowAnyLiquidator, uint256 repaidDebtExpected, uint256 extraDemandedExpected, uint256 minSupplyPostRefi) external nonReentrant returns (uint256 refiOfferNumber, uint256 refiNonce) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (!lending.active) revert InvalidInput("lendingId not active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (msg.sender == lending.borrower) revert InvalidInput("lender == borrower");
        if (block.timestamp >= lending.start + lending.term + lending.gracePeriod) revert InvalidInput("expired");
        if (lending.repaidDebt != repaidDebtExpected) revert InvalidInput("repaid debt mismatch");
        if (lending.refiParams.extraDemanded != extraDemandedExpected) revert InvalidInput("extra demanded mismatch");
        if (lending.supplyAmount - lending.refiParams.supplyPulled < minSupplyPostRefi) revert InvalidInput("min supply post refi");
        if (!lending.refiParams.set) revert InvalidInput("refi params not set");
    
        uint256 amount = totalOwedAtMaturity(lending.borrowAmount, lending.rate, lending.term);
        if (lending.repaidDebt > amount) revert InvalidInput("repaid debt > owed"); //shouldnt ever happen though
        amount -= lending.repaidDebt;
        amount += lending.refiParams.extraDemanded;

        refiNonce = lending.refiOfferNonce;
        refiOfferNumber = lending.refiOfferNumber;
        address borrowToken = lending.borrowToken;

        RefiLendingOffers storage refi = lending.refiLendingOffers[refiNonce][refiOfferNumber];

        lending.refiOfferNumber += 1;

        refi.lender = msg.sender;
        refi.rate = rate;
        refi.amount = amount;
        refi.allowAnyLiquidator = allowAnyLiquidator;
        refi.repaidDebtAtRefiOfferTime = lending.repaidDebt;
        refi.extra = lending.refiParams.extraDemanded; // is this actually needed?
        refi.refiOfferTime = uint48(block.timestamp);

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        emit RefiBorrowOffered(msg.sender, lendingId, rate, refiNonce, refiOfferNumber);

        return (refiOfferNumber, refiNonce);
    }

    /**
     * @notice Cancels borrow offer and returns loan amount back to lender
     * @param lendingId Unique identification number of lending instance
     * @param offerNumber Unique identification number of lender's original offer
     */
    function cancelBorrowOffer(uint256 lendingId, uint256 offerNumber) external nonReentrant {
        uint256 amount = lendingArrangements[lendingId].lendingOffers[offerNumber].amount;
        address lender = lendingArrangements[lendingId].lendingOffers[offerNumber].lender;
        bool chosen = lendingArrangements[lendingId].lendingOffers[offerNumber].chosen;
        bool cancelled = lendingArrangements[lendingId].lendingOffers[offerNumber].cancelled;
        uint256 offerTime = lendingArrangements[lendingId].lendingOffers[offerNumber].offerTime;
        address borrowToken = lendingArrangements[lendingId].borrowToken;

        if (msg.sender != lender) revert InvalidInput("msg.sender");
        if (amount == 0) revert InvalidInput("no borrow offer");
        if (chosen) revert InvalidInput("chosen");
        if (cancelled) revert InvalidInput("cancelled");
        if (block.timestamp < offerTime + 60) revert InvalidInput("cancel too soon");

        lendingArrangements[lendingId].lendingOffers[offerNumber].amount = 0;
        lendingArrangements[lendingId].lendingOffers[offerNumber].cancelled = true;

        IERC20(borrowToken).safeTransfer(lender, amount);

        emit BorrowOfferCancelled(lendingId, offerNumber);

    }

    /**
     * @notice Cancels refi offer and returns loan amount back to lender
     * @param lendingId Unique identification number of lending instance
     * @param refiNonce Unique identification number of refinancing round (one per new loan)
     * @param refiOfferNumber Unique identification number of lender's refi offer
     */
    function cancelRefiBorrowOffer(uint256 lendingId, uint256 refiNonce, uint256 refiOfferNumber) external nonReentrant {
        RefiLendingOffers storage refi = lendingArrangements[lendingId].refiLendingOffers[refiNonce][refiOfferNumber];

        uint256 amount = refi.amount;
        address lender = refi.lender;
        bool chosen = refi.chosen;
        bool cancelled = refi.cancelled;
        uint256 refiOfferTime = refi.refiOfferTime;

        address borrowToken = lendingArrangements[lendingId].borrowToken;

        if (msg.sender != lender) revert InvalidInput("msg.sender");
        if (chosen) revert InvalidInput("chosen");
        if (cancelled) revert InvalidInput("cancelled");
        if (block.timestamp < refiOfferTime + 60) revert InvalidInput("cancel too soon");

        refi.amount = 0;
        refi.cancelled = true;

        IERC20(borrowToken).safeTransfer(lender, amount);

        emit RefiBorrowOfferCancelled(lendingId, refiOfferNumber, refiNonce);

    }

    /**
     * @notice Accepts offer for loan and transfers borrowed amount to borrower
     * @param lendingId Unique identification number of lending instance
     * @param offerNumber Unique identification number of lender's original offer
     */
    function acceptOffer(uint256 lendingId, uint256 offerNumber) external nonReentrant {
        if (lendingArrangements[lendingId].cancelled) revert InvalidInput("lendingId cancelled");
        if (lendingArrangements[lendingId].active) revert InvalidInput("lendingId active");
        if (lendingArrangements[lendingId].finished) revert InvalidInput("lendingId finished");
        if (lendingArrangements[lendingId].borrower != msg.sender) revert InvalidInput("msg.sender");
        if (lendingArrangements[lendingId].lendingOffers[offerNumber].cancelled) revert InvalidInput("offer cancelled");
        if (lendingArrangements[lendingId].lendingOffers[offerNumber].amount == 0) revert InvalidInput("no offer");

        lendingArrangements[lendingId].lendingOffers[offerNumber].chosen = true;

        oracleFeeReceiver feeReceiver = new oracleFeeReceiver(address(this), lendingId, address(oracle), lendingArrangements[lendingId].supplyToken, lendingArrangements[lendingId].borrowToken);
        lendingArrangements[lendingId].feeRecipient = address(feeReceiver);

        lendingArrangements[lendingId].active = true;
        lendingArrangements[lendingId].rate = lendingArrangements[lendingId].lendingOffers[offerNumber].rate;
        lendingArrangements[lendingId].lender = lendingArrangements[lendingId].lendingOffers[offerNumber].lender;
        lendingArrangements[lendingId].borrowAmount = lendingArrangements[lendingId].lendingOffers[offerNumber].amount;
        lendingArrangements[lendingId].start = uint48(block.timestamp);
        lendingArrangements[lendingId].allowAnyLiquidator = lendingArrangements[lendingId].lendingOffers[offerNumber].allowAnyLiquidator;

        IERC20(lendingArrangements[lendingId].borrowToken).safeTransfer(msg.sender, lendingArrangements[lendingId].borrowAmount);

        emit OfferAccepted(lendingId, offerNumber);
    }

    /**
     * @notice Accepts refinancing offer, transfers net new borrowed amount to borrower and transfers old loan amount due at maturity to previous lender
     * @param refiOfferNumber Unique identification number of lender's refi offer
     * @param refiNonce Unique identification number of refinancing round (one per new loan)
     */
    function acceptRefiOffer(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (!lending.active) revert InvalidInput("lendingId not active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (lending.inLiquidation) revert InvalidInput("lendingId in liquidation");
        if (lending.borrower != msg.sender) revert InvalidInput("msg.sender");
        if (lending.refiNonceAccepted[refiNonce]) revert InvalidInput("refi nonce already accepted");
        if (block.timestamp >= lending.start + lending.term + lending.gracePeriod) revert InvalidInput("expired");

        RefiLendingOffers storage refi = lending.refiLendingOffers[refiNonce][refiOfferNumber];

        if (refi.cancelled) revert InvalidInput("refi offer cancelled");
        if (refi.amount == 0) revert InvalidInput("no refi offer");

        address prevLender = lending.lender;
        uint256 repaidDebt = lending.repaidDebt;

        if (refi.repaidDebtAtRefiOfferTime != repaidDebt) revert InvalidInput("repaid debt changed");

        uint256 owed = totalOwedAtMaturity(lending.borrowAmount, lending.rate, lending.term);
        uint256 extraDemanded;
        uint256 supplyPulled;

        if (lending.refiParams.set) {
            extraDemanded = lending.refiParams.extraDemanded;
            supplyPulled = lending.refiParams.supplyPulled;
        } else {
            extraDemanded = 0;
            supplyPulled = 0;
        }

        refi.chosen = true;
        lending.refiNonceAccepted[refiNonce] = true;
        lending.refiOfferNonce += 1;
        lending.refiOfferNumber = 1;

        oracleFeeReceiver feeReceiver = new oracleFeeReceiver(address(this), lendingId, address(oracle), lending.supplyToken, lending.borrowToken);
        lending.feeRecipient = address(feeReceiver);

        lending.rate = refi.rate;
        lending.lender = refi.lender;
        lending.borrowAmount = refi.amount;
        lending.start = uint48(block.timestamp);
        lending.allowAnyLiquidator = refi.allowAnyLiquidator;
        lending.gracePeriod = 0;
        lending.repaidDebt = 0;
        lending.liquidator = address(0);
        lending.liquidationStart = 0; //should be fine already from other logic

        lending.supplyAmount -= supplyPulled;

        lending.refiParams.extraDemanded = 0;
        lending.refiParams.supplyPulled = 0;
        lending.refiParams.set = false;

        _transferTokens(lending.borrowToken, address(this), prevLender, owed);

        if (extraDemanded > 0){
            IERC20(lending.borrowToken).safeTransfer(lending.borrower, extraDemanded);
        }

        if (supplyPulled > 0) {
            IERC20(lending.supplyToken).safeTransfer(lending.borrower, supplyPulled);
        }

        emit RefiOfferAccepted(lendingId, refiOfferNumber, refiNonce);
    }

    // cant be anyone-can-call because of refi invalidation griefing
    /**
     * @notice Repays debt and transfers borrowToken into contract, reducing liquidation risk. 
               If repaid amount is enough to fully pay back total owed, lender is paid back fully and borrower gets collateral back.
               Cannot repay debt during oracle game liquidation.
               If liquidation attempt ends too close to maturity, a short grace period is offered to repay debt or accept refinancing offer.
               Only borrower can call.
               Repaid debt voids prior refi offers.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of debt to repay
     */
    function repayDebt(uint256 lendingId, uint256 amount) external nonReentrant {
        if (lendingArrangements[lendingId].inLiquidation) revert InvalidInput("in liquidation");
        if (lendingArrangements[lendingId].finished) revert InvalidInput("arrangement finished");
        if (!lendingArrangements[lendingId].active) revert InvalidInput("not active");
        if (lendingArrangements[lendingId].cancelled) revert InvalidInput("cancelled");
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        if (block.timestamp >= lendingArrangements[lendingId].start + lendingArrangements[lendingId].term + lendingArrangements[lendingId].gracePeriod) revert InvalidInput("expired");

        uint256 borrowAmount = lendingArrangements[lendingId].borrowAmount;
        uint256 rate = lendingArrangements[lendingId].rate;
        uint256 term = lendingArrangements[lendingId].term;
        uint256 repaid = lendingArrangements[lendingId].repaidDebt;
        uint256 owedAtMaturity = totalOwedAtMaturity(borrowAmount, rate, term);
        address lender = lendingArrangements[lendingId].lender;
        address borrower = lendingArrangements[lendingId].borrower;
        uint256 supplied = lendingArrangements[lendingId].supplyAmount;

        uint256 netTerminalDebt = owedAtMaturity - repaid;

        if (amount >= netTerminalDebt) {
            lendingArrangements[lendingId].finished = true;
            IERC20(lendingArrangements[lendingId].borrowToken).safeTransferFrom(msg.sender, address(this), netTerminalDebt);
            _transferTokens(lendingArrangements[lendingId].borrowToken, address(this), lender, owedAtMaturity);
            IERC20(lendingArrangements[lendingId].supplyToken).safeTransfer(borrower, supplied);
        } else {
        lendingArrangements[lendingId].repaidDebt += amount;
        IERC20(lendingArrangements[lendingId].borrowToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit DebtRepaid(lendingId, amount);

    }

    /**
     * @notice Tops up supplied collateral and transfers supplyToken into contract, reducing liquidation risk. 
               Cannot top up collateral during oracle game liquidation.
               Anyone can call.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of collateral to add to lending position
     */
    function topUpCollateralAnyone(uint256 lendingId, uint256 amount) external nonReentrant {
        _topUpCollateral(lendingId, amount);
    }

    /**
     * @notice Tops up supplied collateral and transfers supplyToken into contract, reducing liquidation risk. 
               Cannot top up collateral during oracle game liquidation.
               Only borrower can call.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of collateral to add to lending position
     */
    function topUpCollateral(uint256 lendingId, uint256 amount) external nonReentrant {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _topUpCollateral(lendingId, amount);
    }

    function _topUpCollateral(uint256 lendingId, uint256 amount) internal {
        if (lendingArrangements[lendingId].inLiquidation) revert InvalidInput("in liquidation");
        if (lendingArrangements[lendingId].finished) revert InvalidInput("arrangement finished");
        if (!lendingArrangements[lendingId].active) revert InvalidInput("not active");
        if (lendingArrangements[lendingId].cancelled) revert InvalidInput("cancelled");

        lendingArrangements[lendingId].supplyAmount += amount;

        IERC20(lendingArrangements[lendingId].supplyToken).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralToppedOff(lendingId, amount);
    }

    /**
     * @notice Lender can claim borrower's supplied collateral and any repaid debt if full loan is not paid back or refinanced at maturity. 
               Respects extra grace period for borrower under late oracle game liquidation attempts.
               Anyone can call.
     * @param lendingId Unique identification number of lending instance
     */
    function claimCollateral(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (block.timestamp < lending.start + lending.term + lending.gracePeriod) revert InvalidInput("not expired");

        lending.finished = true;

        IERC20(lending.supplyToken).safeTransfer(lending.lender, lending.supplyAmount);
        IERC20(lending.borrowToken).safeTransfer(lending.lender, lending.repaidDebt);
        emit CollateralClaimedByLender(lendingId, lending.supplyAmount, lending.repaidDebt);
    }

    /**
     * @notice Borrower can set refinancing parameters to refinance their loan 
               Can only be set once per loan, ahead of prospective refi
     * @param lendingId Unique identification number of lending instance
     * @param extraDemanded Extra amount to borrow on refi
     * @param supplyPulled Amount of supply to pull out on refi
     */
    function changeRefiParams(uint256 lendingId, uint256 extraDemanded, uint256 supplyPulled) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (lending.refiParams.set) revert InvalidInput("params already set");
        if (supplyPulled >= lending.supplyAmount) revert InvalidInput("supplyPulled too high");

        lending.refiParams.extraDemanded = extraDemanded;
        lending.refiParams.supplyPulled = supplyPulled;
        lending.refiParams.set = true;

        emit RefiParamsUpdated(lendingId, extraDemanded, supplyPulled);
    }

    // borrower owes this amount to lender no matter when they pay debt back or refinance
    function totalOwedAtMaturity(uint256 amount, uint256 rate, uint256 term) internal pure returns (uint256) {
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        interest = amount * term * rate / (1e9 * year);
        return amount + interest;
    }

    // borrower's debt is this number during liquidation
    function totalOwedNow(uint256 amount, uint256 rate, uint256 term, uint256 start) internal view returns (uint256) {
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed > term) elapsed = term;
        interest = amount * elapsed * rate / (1e9 * year);
        return amount + interest;
    }

    /**
     * @notice Liquidator bets the stake % * suppliedAmount that the oracle game will resolve to a price that liquidates the borrower.
               Liquidator submits an initial report in the oracle game and transfers tokens to oracle contract.
               Borrower cannot pay back debt or top up collateral during liquidation.
               If liquidation is unsuccessful, stake is given to borrower.
               If liquidation is successful, liquidator gets their stake back and splits remaining equity 50/50 with lender.
               Lender receives all remaining collateral after liquidator split.
               Message value should be equal to (1e15 + 1) wei. Liquidator receives excess over 1e15 back.
     * @param lendingId Unique identification number of lending instance
     * @param expectedCollateral Amount of supplied collateral expected
     * @param expectedRepaidDebt Amount of repaid debt expected
     * @param oracleAmount2 Amount of borrowToken submitted in the oracle game initial report. Must be an amount of borrowToken that is equal in value to expectedInitialLiquidity of supplyToken.
     * @param expectedBorrowAmount Borrow amount expected (borrowAmount in the lendingId)
     * @param expectedLoanStart Timestamp of loan start expected (start in the lendingId)
     * @param expectedStake Amount of supplyToken the liquidator is expected to wager on a successful liquidation
     * @param expectedInitialLiquidity Amount of supplyToken the liquidator expects to submit in the oracle game initial report as token1.
     */
    function liquidate(uint256 lendingId, uint256 expectedCollateral, uint256 expectedRepaidDebt, uint256 oracleAmount2, uint256 expectedBorrowAmount, uint256 expectedLoanStart, uint256 expectedStake, uint256 expectedInitialLiquidity) external payable nonReentrant {
         LendingArrangement storage lending = lendingArrangements[lendingId];

         uint256 tokenStake = lending.supplyAmount * lending.stake / 10000;
         uint256 initialLiquidity = lending.supplyAmount * lending.oracleParams.initialLiquidity / 100;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (!lending.allowAnyLiquidator && msg.sender != lending.lender) revert InvalidInput("wrong liquidator");
        if (lending.supplyAmount != expectedCollateral) revert InvalidInput("expected collateral");
        if (lending.repaidDebt != expectedRepaidDebt) revert InvalidInput("expected repaid debt");
        if (lending.borrowAmount != expectedBorrowAmount) revert InvalidInput("expected borrow amount");
        if (lending.start != expectedLoanStart) revert InvalidInput("expected loan start");
        if (tokenStake != expectedStake) revert InvalidInput("expected stake");
        if (initialLiquidity != expectedInitialLiquidity) revert InvalidInput("initial liquidity expected");
        if (msg.value < 1e15 + 1) revert InvalidInput("msg.value < 1e15 + 1");

        if (block.timestamp > lending.start + lending.term) revert InvalidInput("arrangement expired");

        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: initialLiquidity,
            escalationHalt: lending.supplyAmount * lending.oracleParams.escalationFactor / 100 ,
            settlerReward: 1e15,
            token1Address: lending.supplyToken,
            settlementTime: lending.oracleParams.settlementTime,
            disputeDelay: 60,
            protocolFee: 100000,
            token2Address: lending.borrowToken,
            callbackGasLimit: 1000000,
            feePercentage: 1,
            multiplier: 200,
            timeType: true,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: lending.feeRecipient
        });

        lending.inLiquidation = true;
        lending.liquidationStart = uint48(block.timestamp);
        lending.liquidator = msg.sender;

        uint256 reportId = oracle.createReportInstance{value: msg.value}(
            params
        );

        reportIdToLending[reportId] = lendingId;

        uint256 amount1 = initialLiquidity;

        IERC20(lending.supplyToken).safeTransferFrom(msg.sender, address(this), amount1 + tokenStake);
        IERC20(lending.borrowToken).safeTransferFrom(msg.sender, address(this), oracleAmount2);

        IERC20(lending.supplyToken).safeIncreaseAllowance(address(oracle), amount1);
        IERC20(lending.borrowToken).safeIncreaseAllowance(address(oracle), oracleAmount2);

        oracle.submitInitialReport(reportId, amount1, oracleAmount2, oracle.extraData(reportId).stateHash, msg.sender);

        IERC20(lending.supplyToken).forceApprove(address(oracle), 0);
        IERC20(lending.borrowToken).forceApprove(address(oracle), 0);

        emit LoanLiquidationUnderway(lendingId, reportId);
    }

   /* -------- oracle callback -------- */
   //TODO (big): must make sure nobody can call this when they shouodlnt
    function onSettle(
        uint256 id,
        uint256 price,
        uint256,                  /* ts   (unused) */
        address,
        address
    ) external payable nonReentrant {

        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        uint256 lendingId = reportIdToLending[id];
        if (lendingId == 0) revert InvalidInput("no lendingId for reportId");
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 borrowValueInSupplyTerms;

        uint256 borrowValue = totalOwedNow(lending.borrowAmount, lending.rate, lending.term, lending.start);

        if(borrowValue > lending.repaidDebt) {
            borrowValue -= lending.repaidDebt;
        } else {
            borrowValue = 0;
        }

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);
        uint256 oracleAmount1 = rs.currentAmount1;
        uint256 oracleAmount2 = rs.currentAmount2;
        uint256 tokenStake = lending.supplyAmount * lending.stake / 10000;

        borrowValueInSupplyTerms = (borrowValue * oracleAmount1) / oracleAmount2;

        uint256 liqThresh = lending.supplyAmount * lending.liquidationThreshold / 1e7;

        if(liqThresh < borrowValueInSupplyTerms) {
            lending.finished = true;
            _transferTokens(lending.borrowToken, address(this), lending.lender, lending.repaidDebt);

            if (borrowValueInSupplyTerms > lending.supplyAmount){
                _transferTokens(lending.supplyToken, address(this), lending.lender, lending.supplyAmount);
                _transferTokens(lending.supplyToken, address(this), lending.liquidator, tokenStake);
                emit LiqFinishedUnderwater(lendingId);
            } else {
                uint256 buffer = lending.supplyAmount - borrowValueInSupplyTerms;
                uint256 lenderPiece = buffer / 2;
                uint256 liquidatorPiece = buffer - lenderPiece;

                _transferTokens(lending.supplyToken, address(this), lending.lender, borrowValueInSupplyTerms + lenderPiece);
                _transferTokens(lending.supplyToken, address(this), lending.liquidator, liquidatorPiece + tokenStake);

                emit LiqFinishedWithBuffer(lendingId);
            }
        } else {
            lending.inLiquidation = false;
            lending.supplyAmount += tokenStake;

            // grace period around liquidations that end either too close to maturity (5 minutes) or after it
            if (block.timestamp > lending.start + lending.term - 300){
                lending.gracePeriod = 300 + (uint48(block.timestamp) - lending.liquidationStart) * 2;
            }
            lending.liquidationStart = 0;

            emit LiqUnsuccessful(lendingId);
        }

        oracleFeeReceiver feeReceiver = oracleFeeReceiver(lending.feeRecipient);

        try feeReceiver.collect() {} catch{}

        uint256 supplyBalanceStart = IERC20(lending.supplyToken).balanceOf(address(this));
        try feeReceiver.sweep(lending.supplyToken) {} catch{}
        uint256 supplyBalanceEnd = IERC20(lending.supplyToken).balanceOf(address(this));
        uint256 feesSupply = supplyBalanceEnd > supplyBalanceStart ? supplyBalanceEnd - supplyBalanceStart : 0;

        uint256 borrowBalanceStart = IERC20(lending.borrowToken).balanceOf(address(this));
        try feeReceiver.sweep(lending.borrowToken) {} catch{}
        uint256 borrowBalanceEnd = IERC20(lending.borrowToken).balanceOf(address(this));
        uint256 feesBorrow = borrowBalanceEnd > borrowBalanceStart ? borrowBalanceEnd - borrowBalanceStart : 0;

        uint256 borrowerSupplyFeePiece = feesSupply / 2;
        uint256 lenderSupplyFeePiece = borrowerSupplyFeePiece / 2;
        uint256 liquidatorSupplyFeePiece = feesSupply - borrowerSupplyFeePiece - lenderSupplyFeePiece;

        _transferTokens(lending.supplyToken, address(this), lending.borrower, borrowerSupplyFeePiece);
        _transferTokens(lending.supplyToken, address(this), lending.lender, lenderSupplyFeePiece);
        _transferTokens(lending.supplyToken, address(this), lending.liquidator, liquidatorSupplyFeePiece);

        uint256 borrowerBorrowFeePiece = feesBorrow / 2;
        uint256 lenderBorrowFeePiece = borrowerBorrowFeePiece / 2;
        uint256 liquidatorBorrowFeePiece = feesBorrow - borrowerBorrowFeePiece - lenderBorrowFeePiece;

        _transferTokens(lending.borrowToken, address(this), lending.borrower, borrowerBorrowFeePiece);
        _transferTokens(lending.borrowToken, address(this), lending.lender, lenderBorrowFeePiece);
        _transferTokens(lending.borrowToken, address(this), lending.liquidator, liquidatorBorrowFeePiece);

    }

    /**
     * @dev Internal function to handle token transfers.                
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {

            (bool success, bytes memory returndata) = token.call(
                    abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
                );

            if (success && ((returndata.length > 0 && abi.decode(returndata, (bool))) || 
                (returndata.length == 0 && address(token).code.length > 0))) {
               return;
            }

            tempHolding[to][token] += amount;

        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet) external nonReentrant {
        uint256 amount = tempHolding[msg.sender][tokenToGet];
        if (amount > 0) {
            tempHolding[msg.sender][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), msg.sender, amount);
        }
    }

    // -------------------------------------------------------------------------
    //                              View functions
    // -------------------------------------------------------------------------

    struct LendingView {
        uint48 term;
        uint256 supplyAmount;
        uint256 borrowAmount;
        uint256 amountDemanded;
        uint256 repaidDebt;
        uint256 stake;
        uint24 liquidationThreshold;
        uint48 offerNumber;
        uint48 refiOfferNumber;
        uint48 offerExpiration;
        uint48 start;
        uint48 gracePeriod;
        uint48 liquidationStart;
        uint32 rate;
        address borrower;
        address lender;
        address liquidator;
        address supplyToken;
        address borrowToken;
        address feeRecipient;
        uint256 refiOfferNonce;
        bool cancelled;
        bool active;
        bool inLiquidation;
        bool finished;
        bool allowAnyLiquidator;
    }

    function getLending(uint256 lendingId) external view returns (LendingView memory) {
        LendingArrangement storage l = lendingArrangements[lendingId];
        return LendingView({
            term: l.term,
            supplyAmount: l.supplyAmount,
            borrowAmount: l.borrowAmount,
            amountDemanded: l.amountDemanded,
            repaidDebt: l.repaidDebt,
            stake: l.stake,
            liquidationThreshold: l.liquidationThreshold,
            offerNumber: l.offerNumber,
            refiOfferNumber: l.refiOfferNumber,
            offerExpiration: l.offerExpiration,
            start: l.start,
            gracePeriod: l.gracePeriod,
            liquidationStart: l.liquidationStart,
            rate: l.rate,
            borrower: l.borrower,
            lender: l.lender,
            liquidator: l.liquidator,
            supplyToken: l.supplyToken,
            borrowToken: l.borrowToken,
            feeRecipient: l.feeRecipient,
            refiOfferNonce: l.refiOfferNonce,
            cancelled: l.cancelled,
            active: l.active,
            inLiquidation: l.inLiquidation,
            finished: l.finished,
            allowAnyLiquidator: l.allowAnyLiquidator
        });
    }

    function getRefiParams(uint256 lendingId) external view returns (RefiParams memory) {
        return lendingArrangements[lendingId].refiParams;
    }

    function getOracleParams(uint256 lendingId) external view returns (OracleParams memory) {
        return lendingArrangements[lendingId].oracleParams;
    }

    function getLendingOffer(uint256 lendingId, uint256 offerNumber) external view returns (LendingOffers memory) {
        return lendingArrangements[lendingId].lendingOffers[offerNumber];
    }

    function getRefiLendingOffer(uint256 lendingId, uint256 refiNonce, uint256 refiOfferNumber) external view returns (RefiLendingOffers memory) {
        return lendingArrangements[lendingId].refiLendingOffers[refiNonce][refiOfferNumber];
    }

    function getRefiNonceAccepted(uint256 lendingId, uint256 refiNonce) external view returns (bool) {
        return lendingArrangements[lendingId].refiNonceAccepted[refiNonce];
    }
}
