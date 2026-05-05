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

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PublicSaleHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

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
        view
        override
        returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_)
    {
        // 0. Проверить, что количество USDT в пуле достигнуто было хотя бы однажды
        // 1. Определить направление свапа (покупка или продажа токена)
        // 2. Если покупка токена, то продать токен по фиксированной цене. при условии достижения в пуле определенного количества USDT отключить
        // 3. Если продажа токена, то отдать токен по невыгодной цене (делить пополам от суммы покупки) при условии достижения в пуле определенного количества токена USDT отключить
        // 4. Если достигнуто определенное количество токена USDT в пуле, то свап работает по стандартным правилам пула
        if (_isUsdtCapReached) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        Currency specifiedCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool specifiedIsUsdt = specifiedCurrency == _usdtCurrency;
        bool exactIn = params.amountSpecified < 0;

        uint128 amountSpecifiedAbs = uint128(
            params.amountSpecified > 0
                ? uint256(params.amountSpecified)
                : uint256(-params.amountSpecified)
        );

        if (amountSpecifiedAbs == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        int128 specifiedDelta;
        int128 unspecifiedDelta;

        if (specifiedIsUsdt) {
            // USDT specified:
            // 1 USDT -> 1 META
            // exact in: user pays USDT, receives META
            // exact out: user wants META, pays USDT
            if (exactIn) {
                uint256 metaOut = amountSpecifiedAbs;
                specifiedDelta = -int128(uint128(amountSpecifiedAbs));
                unspecifiedDelta = int128(uint128(metaOut));
            } else {
                uint256 usdtIn = amountSpecifiedAbs;
                specifiedDelta = int128(uint128(usdtIn));
                unspecifiedDelta = -int128(uint128(amountSpecifiedAbs));
            }
        } else {
            // META specified:
            // 1 META -> 0.5 USDT
            // exact in: user pays META, receives USDT
            // exact out: user wants USDT, pays META
            if (exactIn) {
                uint256 usdtOut = amountSpecifiedAbs / 2;
                specifiedDelta = -int128(uint128(amountSpecifiedAbs));
                unspecifiedDelta = int128(uint128(usdtOut));
            } else {
                uint256 metaIn = amountSpecifiedAbs * 2;
                specifiedDelta = int128(uint128(metaIn));
                unspecifiedDelta = -int128(uint128(amountSpecifiedAbs));
            }
        }

        if (params.zeroForOne) {
            return (
                BaseHook.beforeSwap.selector,
                toBeforeSwapDelta(specifiedDelta, unspecifiedDelta),
                0
            );
        } else {
            return (
                BaseHook.beforeSwap.selector,
                toBeforeSwapDelta(unspecifiedDelta, specifiedDelta),
                0
            );
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override adjustUsdtInPool(key, delta) returns (bytes4, int128) {
        if (_usdtInPool >= _usdtCap) {
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