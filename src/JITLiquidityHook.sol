// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract JITLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    struct ActivePosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev Precomputed swap simulation result, reused across preview and add.
    struct Preview {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        int256 pnlInToken1;
    }

    /// @notice Minimum expected PnL (denominated in token1, post-swap price)
    /// to enter the JIT position. Should cover gas of add + remove.
    int256 public immutable minProfitToken1;

    mapping(PoolId => ActivePosition) private _activePositions;

    constructor(IPoolManager _poolManager, int256 _minProfitToken1) BaseHook(_poolManager) {
        minProfitToken1 = _minProfitToken1;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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

    // TODO: will be change on the vault
    function deposit(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        if (amount0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);
        }
    }

    // TODO: will be change on the vault
    function withdraw(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        if (amount0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
        }
    }

    // TODO: remove
    function getActivePosition(PoolKey memory key) external view returns (ActivePosition memory) {
        return _activePositions[key.toId()];
    }

    /// @notice External probe: predicts JIT PnL for a given swap without executing.
    function previewSwap(PoolKey calldata key, SwapParams calldata params)
        external
        view
        returns (Preview memory)
    {
        return _previewSwap(key, params);
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        Preview memory p = _previewSwap(key, params);
        if (p.liquidity > 0 && p.pnlInToken1 >= minProfitToken1) {
            _addLiquidity(key, p);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _removeLiquidity(key);
        return (BaseHook.afterSwap.selector, 0);
    }

    struct SimInputs {
        PoolId poolId;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        uint128 liquidity;
        uint24 fee;
    }

    function _previewSwap(PoolKey calldata key, SwapParams calldata params)
        private
        view
        returns (Preview memory p)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int24 tickSpacing = key.tickSpacing;
        p.tickLower = TickBitmap.compress(currentTick, tickSpacing) * tickSpacing;
        p.tickUpper = p.tickLower + tickSpacing;
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);

        {
            uint256 b0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
            uint256 b1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
            p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, b0, b1
            );
        }
        if (p.liquidity == 0) return p;

        p.pnlInToken1 = _simulatePnL(
            params,
            SimInputs({
                poolId: poolId,
                sqrtPriceX96: sqrtPriceX96,
                sqrtPriceLower: sqrtPriceLower,
                sqrtPriceUpper: sqrtPriceUpper,
                liquidity: p.liquidity,
                fee: key.fee
            })
        );
    }

    function _simulatePnL(SwapParams calldata params, SimInputs memory s)
        private
        view
        returns (int256)
    {
        (uint256 a0Before, uint256 a1Before) =
            _amountsForLiquidity(s.sqrtPriceX96, s.sqrtPriceLower, s.sqrtPriceUpper, s.liquidity);

        uint128 totalL = poolManager.getLiquidity(s.poolId) + s.liquidity;

        uint160 sqrtPriceNext;
        uint256 ourFee;
        {
            uint160 boundary = params.zeroForOne ? s.sqrtPriceLower : s.sqrtPriceUpper;
            uint160 sqrtPriceTarget = SwapMath.getSqrtPriceTarget(
                params.zeroForOne, boundary, params.sqrtPriceLimitX96
            );
            (uint160 next,,, uint256 feeAmount) = SwapMath.computeSwapStep(
                s.sqrtPriceX96, sqrtPriceTarget, totalL, params.amountSpecified, s.fee
            );
            sqrtPriceNext = next;
            ourFee = FullMath.mulDiv(feeAmount, s.liquidity, totalL);
        }

        (uint256 a0After, uint256 a1After) =
            _amountsForLiquidity(sqrtPriceNext, s.sqrtPriceLower, s.sqrtPriceUpper, s.liquidity);
        if (params.zeroForOne) a0After += ourFee;
        else                   a1After += ourFee;

        // priceX96 = sqrtPriceNext^2 / 2^96
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceNext), uint256(sqrtPriceNext), 1 << 96);

        int256 net0 = int256(a0After) - int256(a0Before);
        int256 net1 = int256(a1After) - int256(a1Before);

        int256 net0InToken1 = net0 >= 0
            ? int256(FullMath.mulDiv(uint256(net0), priceX96, 1 << 96))
            : -int256(FullMath.mulDiv(uint256(-net0), priceX96, 1 << 96));

        return net0InToken1 + net1;
    }

    function _addLiquidity(PoolKey calldata key, Preview memory p) private {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: 0
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        _activePositions[key.toId()] = ActivePosition({
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: p.liquidity
        });
    }

    function _removeLiquidity(PoolKey calldata key) private {
        PoolId poolId = key.toId();
        ActivePosition memory pos = _activePositions[poolId];

        if (pos.liquidity == 0) return;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: 0
            }),
            ""
        );

        _take(key.currency0, delta.amount0());
        _take(key.currency1, delta.amount1());

        delete _activePositions[poolId];
    }

    /// @dev Compute (amount0, amount1) for a given liquidity at a given price within a range.
    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        uint128 liquidity
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, false);
        } else if (sqrtPriceX96 >= sqrtPriceUpper) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceX96, liquidity, false);
        }
    }

    /// @dev Settle a negative delta (transfer tokens to pool manager)
    function _settle(Currency currency, int128 delta) private {
        if (delta >= 0) return;
        uint256 amount = uint256(int256(-delta));
        CurrencySettler.settle(currency, poolManager, address(this), amount, false);
    }

    /// @dev Take a positive delta (receive tokens from pool manager)
    function _take(Currency currency, int128 delta) private {
        if (delta <= 0) return;
        uint256 amount = uint256(int256(delta));
        CurrencySettler.take(currency, poolManager, address(this), amount, false);
    }
}
