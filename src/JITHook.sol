// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

import {JIT} from "./JIT.sol";

abstract contract JITHook is JIT {
    using TransientStateLibrary for IPoolManager;

    bytes constant ZERO_BYTES = "";

    constructor(IPoolManager _poolManager) JIT(_poolManager) {
        // safety check that the hook address matches expected flags
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @dev Inheriting contract should override and should pull funds from a source and transfer them to PoolManager
    function _pull(Currency currency0, Currency currency1) internal virtual returns (address, uint128, uint128);

    /// @dev Inheriting contract should override and specify recipient of the JIT position
    function _recipient() internal view virtual returns (address);

    // TODO: restrict onlyByManager
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // transfer Currency from a source to PoolManager and then create a liquidity position
        (address excessRecipient, uint128 amount0, uint128 amount1) = _pull(key.currency0, key.currency1);

        // create JIT position
        (,, uint128 liquidity) = _createPosition(key, amount0, amount1, hookData);
        _storeLiquidity(liquidity);

        // refund excess tokens to recipient
        // TODO: optimization: custom transient reader to fetch balance delta in one external call
        int256 delta0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), key.currency1);
        if (delta0 > 0) poolManager.take(key.currency0, excessRecipient, uint256(delta0));
        if (delta1 > 0) poolManager.take(key.currency1, excessRecipient, uint256(delta1));

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // TODO: restrict onlyByManager
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        // close JIT position
        uint128 liquidity = _loadLiquidity();
        (BalanceDelta delta,) = _closePosition(key, liquidity, hookData);

        // transfer funds to recipient, must use ERC6909 because the swapper has not transferred ERC20 yet
        poolManager.mint(_recipient(), key.currency0.toId(), uint256(int256(delta.amount0())));
        poolManager.mint(_recipient(), key.currency1.toId(), uint256(int256(delta.amount1())));

        return (BaseHook.afterSwap.selector, 0);
    }

    // Utility Functions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
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

    function _storeLiquidity(uint128 liquidity) private {
        bytes32 liquiditySlot;
        assembly {
            tstore(liquiditySlot, liquidity)
        }
    }

    function _loadLiquidity() private view returns (uint128 liquidity) {
        bytes32 liquiditySlot;
        assembly {
            liquidity := tload(liquiditySlot)
        }
    }
}
