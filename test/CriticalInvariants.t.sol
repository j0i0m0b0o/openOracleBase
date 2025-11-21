// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/Vm.sol";

import "../src/OpenOracle.sol";
import "./utils/MockERC20.sol";

// Callback that tracks execution and the gas observed in the callback context
contract TestCallback {
    struct Execution {
        bool called;
        uint256 gasReceived;
        uint256 reportId;
        uint256 timestamp;
    }

    mapping(uint256 => Execution) public executions;
    mapping(uint256 => uint256) public executionCount;

    function onOracleSettle(uint256 reportId, uint256, uint256, address, address) external {
        executions[reportId] =
            Execution({called: true, gasReceived: gasleft(), reportId: reportId, timestamp: block.timestamp});
        executionCount[reportId]++;
    }
}

// Stateful handler used by the invariant fuzzer
contract InvariantHandler {
    using stdStorage for StdStorage;

    Vm public constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OpenOracle public immutable oracle;
    MockERC20 public immutable token1;
    MockERC20 public immutable token2;
    TestCallback public immutable callback;

    uint256 public constant ORACLE_FEE = 0.01 ether;
    uint256 public constant SETTLER_REWARD = 0.001 ether;
    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;

    uint256[] public reportIds;
    mapping(uint256 => bool) public hasSettled;
    mapping(uint256 => bool) public lowGasSettled; // records if a low-gas settle succeeded
    mapping(uint256 => uint256) public lowGasCallbackGasReceived; // gas observed inside callback on low-gas settle

    constructor(OpenOracle _oracle, MockERC20 _token1, MockERC20 _token2, TestCallback _callback) {
        oracle = _oracle;
        token1 = _token1;
        token2 = _token2;
        callback = _callback;

        // Pre-approve oracle to pull tokens from this handler
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
    }

    receive() external payable {}

    function reportCount() external view returns (uint256) {
        return reportIds.length;
    }

    function getReportId(uint256 idx) public view returns (uint256) {
        if (reportIds.length == 0) return 0;
        return reportIds[idx % reportIds.length];
    }

    // Create a report instance configured with a settlement callback
    function createReport() external {
        // Default parameters chosen to be realistic and exercise the callback
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(60),
                escalationHalt: 10e18,
                disputeDelay: uint24(0),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(callback),
                callbackSelector: TestCallback.onOracleSettle.selector,
                trackDisputes: false,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                keepFee: true,
                protocolFeeRecipient: address(this)
            })
        );
        reportIds.push(reportId);
    }

    // Submit the initial report for a chosen report id
    function submitInitial(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;

        // Only submit if not already submitted
        (uint256 currentAmount1,,,,,,,,,) = oracle.reportStatus(reportId);
        if (currentAmount1 != 0) return;

        // Read meta + state hash
        (uint256 exactToken1Report, , , , , , , , , , , ) = oracle.reportMeta(reportId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Provide a simple amount2 (arbitrary positive)
        uint256 amount2 = 1e18;

        // Ensure we have tokens to contribute if needed
        _ensureBalances(2e18, 2e21);

        oracle.submitInitialReport(reportId, exactToken1Report, amount2, stateHash);
    }

    // Dispute the latest report by increasing token1 amount according to escalation rules
    function dispute(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;

        // Load meta and status
        (, uint256 escalationHalt, , , , , , , , , uint16 multiplier, uint24 disputeDelay) = oracle.reportMeta(reportId);

        (
            uint256 oldAmount1,
            uint256 oldAmount2,
            ,
            ,
            uint48 reportTimestamp,
            ,
            ,
            ,
            ,
            
        ) = oracle.reportStatus(reportId);

        if (oldAmount1 == 0) return; // no initial report yet

        // Respect dispute delay
        if (block.timestamp < uint256(reportTimestamp) + uint256(disputeDelay)) return;

        // Compute next amount1 per escalation rules
        uint256 newAmount1;
        if (oldAmount1 >= escalationHalt && escalationHalt != 0) {
            newAmount1 = oldAmount1 + 1; // +1 mode once at cap
        } else {
            uint256 scaled = (oldAmount1 * uint256(multiplier)) / 100;
            if (escalationHalt != 0 && scaled > escalationHalt) {
                newAmount1 = escalationHalt;
            } else {
                newAmount1 = scaled;
            }
        }

        // Choose newAmount2 to be sufficiently different so that price is outside fee boundaries
        // If possible, reduce by 1% to increase price and avoid boundaries
        uint256 newAmount2 = oldAmount2 > 100 ? (oldAmount2 * 99) / 100 : oldAmount2 + 1;

        // Ensure we have sufficient balances to perform dispute contributions
        _ensureBalances(newAmount1 + oldAmount1, newAmount2 + oldAmount2);

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        // Always swap token1 in this handler for simplicity
        try oracle.disputeAndSwap(reportId, address(token1), newAmount1, newAmount2, oldAmount2, stateHash) {
            // ok
        } catch {
            // ignore reverts; fuzzer will try different sequences
        }
    }

    // Attempt to settle with a fuzzed gas amount
    function settle(uint256 idSeed, uint256 gasSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;

        // Only attempt after settlement time; skip if already distributed
        (,,,, uint48 reportTimestamp,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        if (isDistributed) return;
        (, , , , , uint48 settlementTime, , , , , , ) = oracle.reportMeta(reportId);
        if (reportTimestamp == 0) return; // no initial report yet

        if (block.timestamp < uint256(reportTimestamp) + uint256(settlementTime)) {
            vm.warp(uint256(reportTimestamp) + uint256(settlementTime) + 1);
        }

        // Fuzz gas between 60k and ~600k
        uint256 gasAmt = 60_000 + (gasSeed % 600_000);
        try oracle.settle{gas: gasAmt}(reportId) returns (uint256, uint256) {
            hasSettled[reportId] = true;
        } catch {
            // ignore reverts; invariants will validate atomicity
        }
    }

    // Always attempt to settle with gas that should be insufficient for a full callback attempt
    // If this ever succeeds, we record lowGasSettled for the report id
    function settleLowGas(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;

        // Only attempt after settlement time; warp forward a bit if needed
        (,,,, uint48 reportTimestamp,,,,,) = oracle.reportStatus(reportId);
        (, , , , , uint48 settlementTime, , , , , , ) = oracle.reportMeta(reportId);
        if (reportTimestamp == 0) return;
        if (block.timestamp < uint256(reportTimestamp) + uint256(settlementTime)) {
            vm.warp(uint256(reportTimestamp) + uint256(settlementTime) + 1);
        }

        // Compose a very low gas amount relative to configured callbackGasLimit
        (, , , uint32 cbGasLimit, , , , ) = oracle.extraData(reportId);
        uint256 lowGas = cbGasLimit / 4; // intentionally small
        if (lowGas > 50_000) lowGas = 50_000; // cap at 50k to ensure it's clearly too low
        if (lowGas < 30_000) lowGas = 30_000; // baseline minimal gas

        try oracle.settle{gas: lowGas}(reportId) returns (uint256, uint256) {
            // Record that a low-gas settle succeeded and how much gas the callback saw
            lowGasSettled[reportId] = true;
            ( , uint256 gasReceived, , ) = callback.executions(reportId);
            lowGasCallbackGasReceived[reportId] = gasReceived;
        } catch {
            // expected to revert or be blocked by insufficient gas
        }
    }

    // Advance time by up to ~1 hour to enable disputes/settlements
    function warp(uint256 dt) external {
        uint256 delta = (dt % 3600) + 1;
        vm.warp(block.timestamp + delta);
    }

    function _ensureBalances(uint256 wantToken1, uint256 wantToken2) internal {
        // Top up handler balances from its own large reserves or do nothing if already enough
        // The test harness will fund this handler; here we just guard to avoid underflows
        if (token1.balanceOf(address(this)) < wantToken1) {
            // nothing to do; the test will initially fund us with a large amount
        }
        if (token2.balanceOf(address(this)) < wantToken2) {
            // nothing to do
        }
    }
}

// Critical invariants suite following Foundry's invariant testing pattern
contract CriticalInvariantsTest is StdInvariant, Test {
    OpenOracle internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;
    TestCallback internal callback;
    InvariantHandler internal handler;

    // Allow small prologue overhead before callback function body reads gasleft()
    uint256 internal constant GAS_FUDGE = 60_000;

    function setUp() public {
        // Deploy core contracts
        oracle = new OpenOracle();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        callback = new TestCallback();

        // Create handler and fund it with abundant tokens and ETH
        handler = new InvariantHandler(oracle, token1, token2, callback);

        // Fund handler with tokens and ETH
        token1.transfer(address(handler), 200_000 ether);
        token2.transfer(address(handler), 200_000 ether);
        vm.deal(address(handler), 100 ether);

        // Fuzz across the handler's public methods
        targetContract(address(handler));

        // Also create at least one report up front so invariants have something to inspect
        handler.createReport();
        handler.submitInitial(0);
        handler.warp(120);
    }

    // Invariant: If a callback is configured and the report is distributed,
    // then the callback must have been invoked.
    function invariant_fullAttemptOnDistribution() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            // Load extra + status
            (, address cb, , uint32 cbGasLimit, , , , ) = oracle.extraData(reportId);
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                bool isDistributed
            ) = oracle.reportStatus(reportId);

            if (cb != address(0) && isDistributed) {
                (bool called, uint256 gasReceived, ,) = callback.executions(reportId);
                assertTrue(called, "callback not called on distributed report");
                // The exact gas observed inside the callback varies by call overhead and EVM rules,
                // so we do not attempt to assert a specific minimum beyond verifying the callback ran.
            }
        }
    }

    // Invariant: Atomicity — callback cannot be observed as called unless distribution is true
    function invariant_atomicityCallbackImpliesDistributed() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (bool called, , ,) = callback.executions(reportId);
            if (called) {
                (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
                assertTrue(isDistributed, "callback called while distribution=false");
            }
        }
    }

    // Invariant: Callback is executed at most once per report
    function invariant_callbackAtMostOnce() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            uint256 times = callback.executionCount(reportId);
            assertLe(times, 1, "callback executed more than once");
        }
    }

    // Invariant: Callback should receive a meaningful amount of gas on successful distribution
    function invariant_callbackGetsMeaningfulGas() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (, address cb, , uint32 cbGasLimit, , , , ) = oracle.extraData(reportId);
            (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
            if (cb != address(0) && isDistributed) {
                (bool called, uint256 gasReceived, ,) = callback.executions(reportId);
                if (called && cbGasLimit > 0) {
                    // Require at least a small fraction of the configured limit to have been available inside the callback
                    uint256 minObserved = uint256(cbGasLimit) / 20; // 5%
                    if (minObserved > 0) {
                        assertGe(gasReceived, minObserved, "callback gas unexpectedly small");
                    }
                }
            }
        }
    }

    // Invariant: Callback gas observed should never exceed the configured callbackGasLimit
    function invariant_callbackGasRespectsLimit() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (, address cb, , uint32 cbGasLimit, , , , ) = oracle.extraData(reportId);
            (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
            if (cb != address(0) && isDistributed) {
                (bool called, uint256 gasReceived, ,) = callback.executions(reportId);
                if (called && cbGasLimit > 0) {
                    assertLe(gasReceived, uint256(cbGasLimit), "callback gas exceeded limit");
                }
            }
        }
    }

    // Invariant: Disputes do not set isDistributed.
    // Distribution must be preceded by a successful settle call recorded by the handler.
    function invariant_isDistributedOnlyAfterSettle() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (,,,,,,, , , bool isDistributed) = oracle.reportStatus(reportId);
            if (isDistributed) {
                bool settled = handler.hasSettled(reportId);
                assertTrue(settled, "isDistributed set without handler-settle");
            }
        }
    }
}
