// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {XPactHook} from "../src/XPactHook.sol";

/// @notice Deploys PoolManager + XPactHook to X Layer testnet.
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url xlayer_testnet \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// Required env: PRIVATE_KEY
///
/// Hook address encoding (bits must match XPactHook.getHookPermissions):
///   afterInitialize = bit 12 (0x1000)
///   beforeSwap      = bit  7 (0x0080)
///   afterSwap       = bit  6 (0x0040)
///   Required bits   = 0x10C0 in the bottom 14 bits of the address
contract Deploy is Script {
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // ── Pre-compute addresses so we can mine the hook salt before broadcast ──

        // PoolManager: regular CREATE from EOA, address = f(deployer, nonce)
        uint64 pmNonce = vm.getNonce(deployer);
        address expectedPM = vm.computeCreateAddress(deployer, pmNonce);

        // Mine a CREATE2 salt whose resulting address has the correct hook permission bits.
        // Deployer for CREATE2 = CREATE2_FACTORY (not the EOA) because Forge routes
        // `new Contract{salt:}()` through the factory during broadcast.
        bytes memory hookCreation =
            abi.encodePacked(type(XPactHook).creationCode, abi.encode(expectedPM));
        bytes32 hookSalt = _mineHookSalt(CREATE2_FACTORY, HOOK_FLAGS, hookCreation);
        address expectedHook = _create2Address(CREATE2_FACTORY, hookSalt, keccak256(hookCreation));

        // ── Pre-flight logging ──
        console2.log("=== xPact Deploy ===");
        console2.log("Deployer            :", deployer);
        console2.log("PoolManager (expect):", expectedPM);
        console2.log("XPactHook   (expect):", expectedHook);
        console2.log("Hook salt           :");
        console2.logBytes32(hookSalt);
        console2.log("Hook bits (0x10C0)  :", uint160(expectedHook) & Hooks.ALL_HOOK_MASK);
        console2.log("");

        // ── Deploy ──

        vm.startBroadcast(deployerKey);

        // 1. PoolManager — deployer becomes the initial fee controller
        PoolManager poolManager = new PoolManager(deployer);

        // 2. XPactHook — deployed via CREATE2 at the pre-mined address
        XPactHook hook = new XPactHook{salt: hookSalt}(IPoolManager(address(poolManager)));

        vm.stopBroadcast();

        // ── Post-deploy verification ──
        require(
            address(poolManager) == expectedPM,
            "Deploy: PoolManager address mismatch (nonce changed?)"
        );
        require(
            address(hook) == expectedHook,
            "Deploy: XPactHook address mismatch (salt/nonce changed?)"
        );
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS,
            "Deploy: hook permission bits incorrect"
        );

        console2.log("=== Deployed ===");
        console2.log("PoolManager :", address(poolManager));
        console2.log("XPactHook   :", address(hook));
    }

    // ──────────────────────────── internal helpers ─────────────────

    /// Iterates CREATE2 salts until the resulting address has the required hook permission bits.
    /// @param deployer_  The EOA that will broadcast the CREATE2 tx.
    /// @param flags      Required bottom-14-bit mask (e.g. HOOK_FLAGS).
    /// @param creationCode  abi.encodePacked(type(C).creationCode, abi.encode(constructorArgs))
    function _mineHookSalt(address deployer_, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (bytes32 salt)
    {
        bytes32 codeHash = keccak256(creationCode);
        for (uint256 s; s < 200_000; s++) {
            salt = bytes32(s);
            if (uint160(_create2Address(deployer_, salt, codeHash)) & Hooks.ALL_HOOK_MASK == flags) {
                return salt;
            }
        }
        revert("Deploy: no valid hook salt found in 200k iterations");
    }

    /// Standard CREATE2 address derivation.
    function _create2Address(address deployer_, bytes32 salt, bytes32 codeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer_, salt, codeHash))))
        );
    }
}
