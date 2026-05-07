// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams, ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CurrencySettler} from '@uniswap/v4-core/test/utils/CurrencySettler.sol';

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

contract PublicSaleHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    uint256 public constant RATE_PRECISION = 1e18;
    uint256 public constant META_PER_USDT = 8 * RATE_PRECISION; // 8 META per 1 USDT

    uint256 private immutable _usdtCap;

    Currency private _metaCurrency;
    Currency private _usdtCurrency;

    uint256 private _usdtInPool;
    bool private _isUsdtCapReached;

    error ZeroAddress();
    error ZeroUsdtCap();
    error DonateNotAllowed();
    error RemoveLiquidityNotAllowed();
    error InvalidAssets();

    modifier adjustUsdtInPool(PoolKey calldata key, BalanceDelta delta) {
        if (!_isUsdtCapReached) {
            _adjustUsdtInPool(key, delta);
        }

        _;
    }

    constructor(IPoolManager _poolManager, address usdt, address meta, uint256 usdtCap) BaseHook(_poolManager) {
        if (
            address(_poolManager) == address(0)
            || meta == address(0)
            || usdt == address(0)
        ) {
            revert ZeroAddress();
        }

        if (usdtCap == 0) {
            revert ZeroUsdtCap();
        }

        _metaCurrency = Currency.wrap(meta);
        _usdtCurrency = Currency.wrap(usdt);

        _usdtCap = usdtCap;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function getUsdtInPool() external view returns (uint256) {
        return _usdtInPool;
    }

    function getUsdtCap() external view returns (uint256) {
        return _usdtCap;
    }

    function getUsdtCurrency() external view returns (Currency) {
        return _usdtCurrency;
    }

    function getMetaCurrency() external view returns (Currency) {
        return _metaCurrency;
    }

    function isUsdtCapReached() external view returns (bool) {
        return _isUsdtCapReached;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        bool isValidPair =
            (key.currency0 == _usdtCurrency && key.currency1 == _metaCurrency) ||
            (key.currency0 == _metaCurrency && key.currency1 == _usdtCurrency);

        if (!isValidPair) {
            revert InvalidAssets();
        }

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    )
        internal
        override
        returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_)
    {
        if (_isUsdtCapReached) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        (int128 specifiedDelta, int128 unspecifiedDelta) = _getDeltas(key, params);

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(specifiedDelta, unspecifiedDelta),
            0 | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override adjustUsdtInPool(key, delta) returns (bytes4, int128) {
        if (!_isUsdtCapReached && _usdtInPool >= _usdtCap) {
            _isUsdtCapReached = true;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override adjustUsdtInPool(key, delta) returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (!_isUsdtCapReached) {
            revert RemoveLiquidityNotAllowed();
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override adjustUsdtInPool(key, delta) returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (!_isUsdtCapReached) {
            revert DonateNotAllowed();
        }

        return BaseHook.beforeDonate.selector;
    }

    function _getAmounts(PoolKey memory key, SwapParams memory params) private view returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        (,amountIn, amountOut,) = SwapMath.computeSwapStep({
            sqrtPriceCurrentX96: sqrtPriceX96,
            sqrtPriceTargetX96: params.sqrtPriceLimitX96,
            liquidity: poolManager.getLiquidity(poolId),
            amountRemaining: params.amountSpecified,
            feePips: 0
        });
    }

    function _getDeltas(PoolKey memory key, SwapParams memory params) private returns (int128 specifiedDelta, int128 unspecifiedDelta) {
        (uint256 amountIn, uint256 amountOut) = _getAmounts(key, params);

        bool exactIn = params.amountSpecified < 0;
        uint256 amountSpecifiedAbs = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

        if (params.zeroForOne) {
            if (exactIn) {
                uint256 metaAmount = amountSpecifiedAbs * META_PER_USDT / RATE_PRECISION;
                uint256 excess = metaAmount > amountOut ? metaAmount - amountOut : 0;

                key.currency1.settle(poolManager, address(this), excess, false);

                specifiedDelta = 0;
                unspecifiedDelta = -int128(uint128(excess));
            } else {
                uint256 usdtAmount = amountSpecifiedAbs * RATE_PRECISION / META_PER_USDT;
                uint256 excess = amountIn > usdtAmount ? amountIn - usdtAmount : 0;

                key.currency0.settle(poolManager, address(this), excess, false);

                specifiedDelta = 0;
                unspecifiedDelta = -int128(uint128(excess));
            }
        } else {
            if (exactIn) {
                uint256 usdtAmount = amountSpecifiedAbs * RATE_PRECISION / META_PER_USDT;
                uint256 excess = amountOut > usdtAmount ? amountOut - usdtAmount : 0;

                poolManager.take(key.currency0, address(0), excess);

                specifiedDelta = 0;
                unspecifiedDelta = int128(uint128(excess));
            }
            else {
                uint256 metaAmount = amountSpecifiedAbs * META_PER_USDT / RATE_PRECISION;
                uint256 excess = metaAmount > amountIn ? metaAmount - amountIn : 0;

                poolManager.take(key.currency1, address(0), excess);

                specifiedDelta = 0;
                unspecifiedDelta = int128(uint128(excess));
            }
        }
    }

    // TODO: rename adjust to account
    function _adjustUsdtInPool(PoolKey calldata key, BalanceDelta delta) private {
        bool usdtIsCurrency0 = key.currency0 == _usdtCurrency;
        int128 usdtDelta = usdtIsCurrency0 ? delta.amount0() : delta.amount1();

        // If usdtDelta is negative, it means that USDT is coming into the pool (user pay), so we add it to the total.
        // If it's positive, it means USDT is leaving the pool, so we subtract it from the total.
        if (usdtDelta < 0) {
            _usdtInPool += uint256(uint128(-usdtDelta));
        } else {
            _usdtInPool -= uint256(uint128(usdtDelta));
        }
    }
}