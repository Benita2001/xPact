// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {IERC20Minimal as IERC20} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";

/// @notice Uniswap V4 hook enabling AI agents to create, accept, and settle service agreements trustlessly.
/// Payment is locked on CREATE and auto-released to agentB on verified delivery.
///
/// Hook flags required (afterInitialize | beforeSwap | afterSwap):
///   bit 12 (0x1000) + bit 7 (0x0080) + bit 6 (0x0040) = 0x10C0
/// Deploy address must end in ...10C0 via CREATE2 mine.
contract XPactHook is BaseHook {
    // ──────────────────────────── types ────────────────────────────

    enum PactStatus {
        Open,
        Active,
        Settled,
        Cancelled
    }

    struct Pact {
        bytes32 id;
        address agentA;
        address agentB;
        string jobDescription;
        uint256 payment;
        address paymentToken;
        bytes32 resultHash;
        PactStatus status;
        uint256 createdAt;
        uint256 deadline;
    }

    // ──────────────────────────── constants ────────────────────────

    uint8 internal constant ACTION_CREATE = 0;
    uint8 internal constant ACTION_ACCEPT = 1;
    uint8 internal constant ACTION_DELIVER = 2;
    uint8 internal constant ACTION_CANCEL = 3;

    // ──────────────────────────── storage ──────────────────────────

    mapping(bytes32 => Pact) public pacts;
    mapping(address => uint256) public reputation;

    // ──────────────────────────── events ───────────────────────────

    event PactCreated(
        bytes32 indexed id,
        address indexed agentA,
        uint256 payment,
        address paymentToken,
        uint256 deadline
    );
    event PactAccepted(bytes32 indexed id, address indexed agentB);
    event PactDelivered(bytes32 indexed id, address indexed agentB, bytes32 resultHash);
    event PactSettled(bytes32 indexed id, address indexed agentB, uint256 payment);

    // ──────────────────────────── errors ───────────────────────────

    error PactNotFound(bytes32 id);
    error PactNotOpen(bytes32 id);
    error PactNotActive(bytes32 id);
    error NotAgentB(bytes32 id);
    error NotAgentA(bytes32 id);
    error DeadlineExpired(bytes32 id);
    error PaymentTransferFailed();
    error ZeroPayment();
    error EmptyJobDescription();

    // ──────────────────────────── constructor ──────────────────────

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ──────────────────────────── hook permissions ─────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──────────────────────────── hook callbacks ───────────────────

    /// Records pool initialization. No-op beyond selector return.
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// Intercepts hookData to detect CREATE, ACCEPT, DELIVER, or CANCEL actions.
    /// Payment is pulled from the sender (requires prior ERC20 approval) on CREATE.
    function beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (hookData.length > 0) {
            (uint8 action, bytes memory payload) = abi.decode(hookData, (uint8, bytes));

            if (action == ACTION_CREATE) {
                _handleCreate(sender, payload);
            } else if (action == ACTION_ACCEPT) {
                _handleAccept(sender, payload);
            } else if (action == ACTION_DELIVER) {
                _handleDeliver(sender, payload);
            } else if (action == ACTION_CANCEL) {
                _handleCancel(sender, payload);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Releases locked payment to agentB when the pact referenced in hookData is Settled.
    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (hookData.length > 0) {
            (uint8 action, bytes memory payload) = abi.decode(hookData, (uint8, bytes));
            if (action == ACTION_DELIVER) {
                (bytes32 pactId,) = abi.decode(payload, (bytes32, bytes32));
                Pact storage pact = pacts[pactId];
                if (pact.status == PactStatus.Settled) {
                    _releasePayout(pact);
                }
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ──────────────────────────── internal logic ───────────────────

    /// agentA creates a new pact and locks payment in this contract.
    /// payload = abi.encode(string jobDescription, uint256 payment, address paymentToken, uint256 deadline)
    function _handleCreate(address sender, bytes memory payload) internal {
        (string memory jobDescription, uint256 payment, address paymentToken, uint256 deadline) =
            abi.decode(payload, (string, uint256, address, uint256));

        if (payment == 0) revert ZeroPayment();
        if (bytes(jobDescription).length == 0) revert EmptyJobDescription();

        bytes32 id = keccak256(abi.encodePacked(sender, block.timestamp, jobDescription, payment));

        bool ok = IERC20(paymentToken).transferFrom(sender, address(this), payment);
        if (!ok) revert PaymentTransferFailed();

        pacts[id] = Pact({
            id: id,
            agentA: sender,
            agentB: address(0),
            jobDescription: jobDescription,
            payment: payment,
            paymentToken: paymentToken,
            resultHash: bytes32(0),
            status: PactStatus.Open,
            createdAt: block.timestamp,
            deadline: deadline
        });

        emit PactCreated(id, sender, payment, paymentToken, deadline);
    }

    /// agentB accepts an Open pact, becoming the job taker.
    /// payload = abi.encode(bytes32 pactId)
    function _handleAccept(address sender, bytes memory payload) internal {
        bytes32 pactId = abi.decode(payload, (bytes32));
        Pact storage pact = pacts[pactId];

        if (pact.agentA == address(0)) revert PactNotFound(pactId);
        if (pact.status != PactStatus.Open) revert PactNotOpen(pactId);
        if (block.timestamp > pact.deadline) revert DeadlineExpired(pactId);

        pact.agentB = sender;
        pact.status = PactStatus.Active;

        emit PactAccepted(pactId, sender);
    }

    /// agentB delivers work by submitting a result hash, moving pact to Settled.
    /// afterSwap will then release payment.
    /// payload = abi.encode(bytes32 pactId, bytes32 resultHash)
    function _handleDeliver(address sender, bytes memory payload) internal {
        (bytes32 pactId, bytes32 resultHash) = abi.decode(payload, (bytes32, bytes32));
        Pact storage pact = pacts[pactId];

        if (pact.agentA == address(0)) revert PactNotFound(pactId);
        if (pact.status != PactStatus.Active) revert PactNotActive(pactId);
        if (pact.agentB != sender) revert NotAgentB(pactId);

        pact.resultHash = resultHash;
        pact.status = PactStatus.Settled;

        emit PactDelivered(pactId, sender, resultHash);
    }

    /// agentA cancels an Open pact and reclaims the locked payment.
    /// payload = abi.encode(bytes32 pactId)
    function _handleCancel(address sender, bytes memory payload) internal {
        bytes32 pactId = abi.decode(payload, (bytes32));
        Pact storage pact = pacts[pactId];

        if (pact.agentA == address(0)) revert PactNotFound(pactId);
        if (pact.agentA != sender) revert NotAgentA(pactId);
        if (pact.status != PactStatus.Open) revert PactNotOpen(pactId);

        pact.status = PactStatus.Cancelled;

        bool ok = IERC20(pact.paymentToken).transfer(sender, pact.payment);
        if (!ok) revert PaymentTransferFailed();
    }

    /// Transfers locked payment to agentB and increments their reputation score.
    function _releasePayout(Pact storage pact) internal {
        address agentB = pact.agentB;
        uint256 amount = pact.payment;
        address token = pact.paymentToken;

        reputation[agentB] += 1;

        bool ok = IERC20(token).transfer(agentB, amount);
        if (!ok) revert PaymentTransferFailed();

        emit PactSettled(pact.id, agentB, amount);
    }
}
