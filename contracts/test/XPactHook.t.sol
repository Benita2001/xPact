// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {XPactHook} from "../src/XPactHook.sol";

/// @dev CREATE is tested via hook.createPact{value}() directly.
///      ACCEPT/DELIVER/CANCEL use vm.prank(address(manager)) + hook.beforeSwap(), bypassing the full swap stack.
contract XPactHookTest is Test {
    // ──────────────────────────── constants ────────────────────────

    uint256 constant PAYMENT = 1 ether;
    string constant JOB_DESC = "Build a smart contract for xPact";
    bytes32 constant RESULT_HASH = keccak256("work_completed_ipfs_hash");

    uint160 constant HOOK_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // ──────────────────────────── state ────────────────────────────

    PoolManager manager;
    XPactHook hook;

    address agentA;
    address agentB;

    // ──────────────────────────── setup ────────────────────────────

    function setUp() public {
        agentA = makeAddr("agentA");
        agentB = makeAddr("agentB");

        vm.deal(agentA, PAYMENT * 10);

        manager = new PoolManager(address(this));
        hook = _deployHook(IPoolManager(address(manager)));
    }

    // ──────────────────────────── tests ────────────────────────────

    function test_CreatePact() public {
        uint256 deadline = block.timestamp + 7 days;
        bytes32 expectedId = _pactId(agentA, block.timestamp);

        vm.expectEmit(address(hook));
        emit XPactHook.PactCreated(expectedId, agentA, PAYMENT, deadline);

        vm.prank(agentA);
        hook.createPact{value: PAYMENT}(JOB_DESC, deadline);

        (
            bytes32 id,
            address a,
            address b,
            ,
            uint256 payment,
            ,
            XPactHook.PactStatus status,
            ,
        ) = hook.pacts(expectedId);

        assertEq(id, expectedId, "pact id mismatch");
        assertEq(a, agentA, "agentA mismatch");
        assertEq(b, address(0), "agentB should be unset");
        assertEq(payment, PAYMENT, "payment amount mismatch");
        assertEq(uint8(status), uint8(XPactHook.PactStatus.Open), "status should be Open");
        assertEq(address(hook).balance, PAYMENT, "hook should hold OKB payment");
    }

    function test_AcceptPact() public {
        uint256 deadline = block.timestamp + 7 days;
        bytes32 pactId = _pactId(agentA, block.timestamp);

        // prerequisite: create the pact
        vm.prank(agentA);
        hook.createPact{value: PAYMENT}(JOB_DESC, deadline);

        vm.expectEmit(address(hook));
        emit XPactHook.PactAccepted(pactId, agentB);

        vm.prank(address(manager));
        hook.beforeSwap(agentB, _dummyKey(), _dummySwapParams(), _encodeAccept(pactId));

        (, , address b, , , , XPactHook.PactStatus status, , ) = hook.pacts(pactId);

        assertEq(b, agentB, "agentB mismatch");
        assertEq(uint8(status), uint8(XPactHook.PactStatus.Active), "status should be Active");
    }

    function test_DeliverPact() public {
        uint256 deadline = block.timestamp + 7 days;
        bytes32 pactId = _pactId(agentA, block.timestamp);
        bytes memory deliverData = _encodeDeliver(pactId);

        // prerequisite: create then accept
        vm.prank(agentA);
        hook.createPact{value: PAYMENT}(JOB_DESC, deadline);

        vm.prank(address(manager));
        hook.beforeSwap(agentB, _dummyKey(), _dummySwapParams(), _encodeAccept(pactId));

        // deliver: beforeSwap sets status to Settled and emits PactDelivered
        vm.expectEmit(address(hook));
        emit XPactHook.PactDelivered(pactId, agentB, RESULT_HASH);

        vm.prank(address(manager));
        hook.beforeSwap(agentB, _dummyKey(), _dummySwapParams(), deliverData);

        // afterSwap sees Settled pact and releases OKB payment to agentB
        vm.expectEmit(address(hook));
        emit XPactHook.PactSettled(pactId, agentB, PAYMENT);

        vm.prank(address(manager));
        hook.afterSwap(address(0), _dummyKey(), _dummySwapParams(), BalanceDelta.wrap(0), deliverData);

        // assertions
        (, , , , , bytes32 rHash, XPactHook.PactStatus status, , ) = hook.pacts(pactId);

        assertEq(rHash, RESULT_HASH, "result hash mismatch");
        assertEq(uint8(status), uint8(XPactHook.PactStatus.Settled), "status should be Settled");
        assertEq(agentB.balance, PAYMENT, "agentB should receive OKB payment");
        assertEq(address(hook).balance, 0, "hook should have no remaining balance");
        assertEq(hook.reputation(agentB), 1, "agentB reputation should increment");
    }

    // ──────────────────────────── helpers ──────────────────────────

    /// Mines a CREATE2 salt so the deployed address has the required hook permission bits.
    function _deployHook(IPoolManager _manager) internal returns (XPactHook deployed) {
        bytes memory creationCode =
            abi.encodePacked(type(XPactHook).creationCode, abi.encode(address(_manager)));
        bytes32 codeHash = keccak256(creationCode);

        for (uint256 s; s < 200_000; s++) {
            bytes32 salt = bytes32(s);
            address candidate = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), salt, codeHash)))
                )
            );
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && candidate.code.length == 0) {
                deployed = new XPactHook{salt: salt}(_manager);
                return deployed;
            }
        }
        revert("XPactHookTest: salt not found");
    }

    /// Computes the pactId the same way XPactHook.createPact does.
    function _pactId(address sender, uint256 ts) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, ts, JOB_DESC, PAYMENT));
    }

    function _dummyKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(hook))
        });
    }

    function _dummySwapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    }

    function _encodeAccept(bytes32 pactId) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), abi.encode(pactId));
    }

    function _encodeDeliver(bytes32 pactId) internal pure returns (bytes memory) {
        return abi.encode(uint8(2), abi.encode(pactId, RESULT_HASH));
    }
}
