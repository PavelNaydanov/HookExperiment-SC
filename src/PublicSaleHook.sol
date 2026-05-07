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

/// @title PublicSaleHook
/// @notice Uniswap v4 hook that runs a fixed-rate public sale phase for a META/USDT pool.
/// @dev While the cumulative USDT entering the pool is below `usdtCap`, every swap executes at
///      the fixed rate of `META_PER_USDT` META per USDT with zero LP fees. Liquidity removal and
///      donations are also blocked during this phase. Once the cap is reached, the hook deactivates
///      its custom logic and the pool transitions permanently to standard Uniswap v4 AMM mechanics.
///
///      Price enforcement works by computing the AMM's native output via `SwapMath.computeSwapStep`
///      and then settling or burning the difference between that output and the fixed-rate output so
///      the net effect on the swapper matches the 1:8 USDT→META rate exactly.
contract PublicSaleHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /// @notice Precision denominator used for fixed-point rate arithmetic.
    uint256 public constant RATE_PRECISION = 1e18;

    /// @notice Fixed exchange rate: META tokens issued per 1 USDT, scaled by `RATE_PRECISION`.
    uint256 public constant META_PER_USDT = 8 * RATE_PRECISION; // 8 META per 1 USDT

    /// @notice Total USDT (in token native units) that must enter the pool to end the public sale.
    uint256 private immutable _usdtCap;

    /// @notice META token currency registered with Uniswap v4.
    Currency private _metaCurrency;

    /// @notice USDT currency registered with Uniswap v4.
    Currency private _usdtCurrency;

    /// @notice Cumulative net USDT that has entered the pool since deployment.
    uint256 private _usdtInPool;

    /// @notice `true` once `_usdtInPool` reaches `_usdtCap`; permanently disables public-sale logic.
    bool private _isUsdtCapReached;

    error ZeroAddress();
    error ZeroUsdtCap();
    error DonateNotAllowed();
    error RemoveLiquidityNotAllowed();
    error InvalidAssets();

    /// @notice Accumulates net USDT flow into `_usdtInPool` after each swap or liquidity addition,
    ///         but only while the public sale phase is active.
    /// @param key   Pool key identifying which pool the operation belongs to.
    /// @param delta Balance delta produced by the operation.
    modifier trackUsdtVolume(PoolKey calldata key, BalanceDelta delta) {
        if (!_isUsdtCapReached) {
            _trackUsdtVolume(key, delta);
        }

        _;
    }

    /// @notice Deploys the hook and configures the public sale parameters.
    /// @param _poolManager Uniswap v4 PoolManager contract.
    /// @param usdt         Address of the USDT token.
    /// @param meta         Address of the META token.
    /// @param usdtCap      Cumulative USDT amount (in token native units) required to end the sale phase.
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

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
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

    /// @notice Returns the cumulative net USDT that has entered the pool.
    function getUsdtInPool() external view returns (uint256) {
        return _usdtInPool;
    }

    /// @notice Returns the USDT cap that ends the public sale phase when reached.
    function getUsdtCap() external view returns (uint256) {
        return _usdtCap;
    }

    /// @notice Returns the USDT currency used by this hook.
    function getUsdtCurrency() external view returns (Currency) {
        return _usdtCurrency;
    }

    /// @notice Returns the META currency used by this hook.
    function getMetaCurrency() external view returns (Currency) {
        return _metaCurrency;
    }

    /// @notice Returns `true` if the USDT cap has been reached and the pool is in standard AMM mode.
    function isUsdtCapReached() external view returns (bool) {
        return _isUsdtCapReached;
    }

    /// @dev Validates that the initializing pool uses exactly the META/USDT currency pair.
    ///      Reverts with `InvalidAssets` for any other pair.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        bool isValidPair =
            (key.currency0 == _usdtCurrency && key.currency1 == _metaCurrency) ||
            (key.currency0 == _metaCurrency && key.currency1 == _usdtCurrency);

        if (!isValidPair) {
            revert InvalidAssets();
        }

        return BaseHook.beforeInitialize.selector;
    }

    /// @dev During the public sale phase, intercepts the swap to enforce the fixed META/USDT rate
    ///      and zero LP fees. Returns a `BeforeSwapDelta` that adjusts for any difference between
    ///      the AMM spot output and the fixed-rate output, settling or taking the surplus from this
    ///      hook's own balance. After the cap is reached, returns neutral deltas and does not interfere.
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

    /// @dev After each swap, checks whether the cumulative USDT cap has been reached and, if so,
    ///      permanently sets `_isUsdtCapReached` to disable public-sale logic going forward.
    ///      USDT volume accounting is delegated to the `trackUsdtVolume` modifier.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override trackUsdtVolume(key, delta) returns (bytes4, int128) {
        if (!_isUsdtCapReached && _usdtInPool >= _usdtCap) {
            _isUsdtCapReached = true;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev Tracks USDT deposited via liquidity additions. Volume accounting is handled by the
    ///      `trackUsdtVolume` modifier; the returned delta is unchanged.
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override trackUsdtVolume(key, delta) returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    /// @dev Blocks liquidity removal while the public sale is active.
    ///      Reverts with `RemoveLiquidityNotAllowed`.
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

    /// @dev Blocks donations while the public sale is active. Reverts with `DonateNotAllowed`.
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

    /// @dev Computes the AMM's native `amountIn` and `amountOut` for the current pool state using
    ///      `SwapMath.computeSwapStep` with zero fee. Used as a baseline to calculate the delta
    ///      adjustment required to match the fixed rate.
    /// @return amountIn  Tokens the AMM would consume at the current spot price.
    /// @return amountOut Tokens the AMM would produce at the current spot price.
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

    /// @dev Computes the `specifiedDelta` and `unspecifiedDelta` needed to enforce the fixed rate.
    ///      If the AMM output differs from the fixed-rate output, the hook either settles the shortfall
    ///      from its own balance or burns the surplus by taking it to `address(0)`.
    ///
    ///      Four cases:
    ///      - zeroForOne + exactIn:  user pays USDT; hook tops up META if AMM output is below fixed rate.
    ///      - zeroForOne + exactOut: user receives META; hook subsidizes USDT if AMM requires more than fixed rate.
    ///      - oneForZero + exactIn:  user pays META; hook burns excess USDT output above fixed rate.
    ///      - oneForZero + exactOut: user receives USDT; hook burns excess META input above fixed rate.
    /// @return specifiedDelta   Hook's adjustment on the swap-specified side (always 0 — AMM handles it).
    /// @return unspecifiedDelta Hook's adjustment on the unspecified side to match the fixed rate.
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

    /// @dev Updates `_usdtInPool` based on the USDT component of `delta`.
    ///      A negative USDT delta means USDT flowed into the pool (user is paying), so the counter
    ///      increments. A positive delta means USDT flowed out (e.g. liquidity removal), so it decrements.
    function _trackUsdtVolume(PoolKey calldata key, BalanceDelta delta) private {
        bool usdtIsCurrency0 = key.currency0 == _usdtCurrency;
        int128 usdtDelta = usdtIsCurrency0 ? delta.amount0() : delta.amount1();

        if (usdtDelta < 0) {
            _usdtInPool += uint256(uint128(-usdtDelta));
        } else {
            _usdtInPool -= uint256(uint128(usdtDelta));
        }
    }
}