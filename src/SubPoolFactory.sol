// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Auth} from "./Auth.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IAggregatorV3Interface} from "./interfaces/chainlink.sol";
import {SubPool} from "./SubPool.sol";
import {ISubPoolFactory} from "./interfaces/ISubPoolFactory.sol";

contract SubPoolFactory is Auth, ISubPoolFactory {
    error SubPoolFactory__UnauthorizedCollateral();
    error SubPoolFactory__InvalidPrice();
    error SubPoolFactory__InsufficientCollateral();
    error SubPoolFactory__UnknownPool();
    error SubPoolFactory__ExitDelayNotElapsed();
    error SubPoolFactory__InvalidPriceFeed();
    error SubPoolFactory__FreezeTimestampNotElapsedYet();
    error SubPoolFactory__CannotPoke();
    error SubPoolFactory__CannotThaw();
    error SubPoolFactory__PoolHasNotQuitYet();
    error SubPoolFactory__PoolAlreadyQuit();
    error SubPoolFactory__PoolAlreadyExited();

    event UpdateCollateral(address indexed collateral, address feed);
    event UpdateExitDelay(uint256 newDelay);
    event UpdateFreezeDelay(uint256 newDelay);
    event UpdateMinCowAmt(uint256 amt);
    event UpdateMinUsdAmt(uint256 amt);

    struct SubPoolData {
        /// The collateral token that pool was initialized with.
        address collateral;
        /// The timestamp at which the pool can exit.
        uint104 exitTimestamp;
        /// The timestamp at which the pool can be frozen.
        uint104 freezeTimestamp;
        /// Whether the pool is frozen.
        bool isFrozen;
        /// Whether the pool has exited.
        bool hasExited;
    }

    struct Config {
        /// the delay between `quit` and `exit`.
        uint24 exitDelay;
        /// @notice the delay between `poke` / `fine` and `freeze`.
        uint24 freezeDelay;
        /// @notice minimum amount of COW to be bonded.
        uint104 minCowAmt;
        /// @notice minimum $ amount of tokens to be bonded expressed as `USD_DECIMALS` decimals.
        uint104 minUsdAmt;
    }

    /// @notice mapping of token to chainlink price feed
    mapping(address => IAggregatorV3Interface) public priceFeeds;
    /// @notice Individual subpool datas
    mapping(address => SubPoolData) public subPoolData;
    /// @notice system cfg
    Config public cfg;
    /// @notice COW token
    address public immutable COW;
    uint256 internal constant USD_DECIMALS = 8;

    constructor(uint24 exitDelay, uint24 freezeDelay, uint104 minCowAmt, uint104 minUsdAmt, address cow) {
        cfg = Config({exitDelay: exitDelay, freezeDelay: freezeDelay, minCowAmt: minCowAmt, minUsdAmt: minUsdAmt});
        emit UpdateExitDelay(exitDelay);
        emit UpdateFreezeDelay(freezeDelay);
        emit UpdateMinCowAmt(minCowAmt);
        emit UpdateMinUsdAmt(minUsdAmt);
        COW = cow;
    }

    /// @notice Set the delay between `quit` and `exit`.
    function setExitDelay(uint24 delay) external auth {
        cfg.exitDelay = delay;
        emit UpdateExitDelay(delay);
    }

    /// @notice Set the delay between `poke` / `fine` and `freeze`.
    function setFreezeDelay(uint24 delay) external auth {
        cfg.freezeDelay = delay;
        emit UpdateFreezeDelay(delay);
    }

    /// @notice Set the min cow amount.
    function setMinCowAmt(uint104 amt) external auth {
        cfg.minCowAmt = amt;
        emit UpdateMinCowAmt(amt);
    }

    /// @notice Set the min usd amount.
    function setMinUsdAmt(uint104 amt) external auth {
        cfg.minUsdAmt = amt;
        emit UpdateMinUsdAmt(amt);
    }

    /// @notice Allow `token` to be used as collateral.
    function allowCollateral(address token, address feed) external auth {
        if (feed == address(0)) revert SubPoolFactory__InvalidPriceFeed();
        _updateCollateralFeed(token, feed);
    }

    /// @notice Deny `token` to be used as collateral.
    function revokeCollateral(address token) external auth {
        _updateCollateralFeed(token, address(0));
    }

    /// @notice Create a `SubPool` for the user at a deterministic address with salt as `msg.sender`.
    /// @param token  - The token to use as collateral.
    /// @param amt    - Amount of token to seed the pool with.
    /// @param cowAmt - Amount of COW token to seed the pool with.
    function create(address token, uint256 amt, uint256 cowAmt) external returns (address) {
        SubPool subpool = new SubPool{salt: bytes32(uint256(uint160(msg.sender)))}(msg.sender, COW);
        subpool.initializeCollateralToken(token);
        Config memory config = cfg;

        if (_usdValue(token, amt) < config.minUsdAmt || cowAmt < config.minCowAmt) {
            revert SubPoolFactory__InsufficientCollateral();
        }

        SafeTransferLib.safeTransferFrom(token, msg.sender, address(subpool), amt);
        SafeTransferLib.safeTransferFrom(COW, msg.sender, address(subpool), cowAmt);

        subPoolData[address(subpool)] =
            SubPoolData({collateral: token, exitTimestamp: 0, freezeTimestamp: 0, isFrozen: false, hasExited: false});

        return address(subpool);
    }

    /// @notice Mark the `pool` as under-collateralized if so depending on price sourced from chainlink oracles.
    function poke(address pool) external {
        _poke(pool, true);
    }

    /// @notice Fine a subpool
    /// @param pool   - The subpool to fine.
    /// @param amt    - Amount of pool's collateralToken to fine.
    /// @param cowAmt - Amount of COW to fine.
    function fine(address pool, uint256 amt, uint256 cowAmt) external auth {
        SubPool(pool).slip(amt, cowAmt, msg.sender);
        _poke(pool, false);
    }

    /// @notice Freeze a pool if they are under-collateralized.
    function freeze(address pool) external {
        SubPoolData memory subpoolData = subPoolData[pool];
        if (block.timestamp >= subpoolData.freezeTimestamp) {
            subpoolData.freezeTimestamp = 0;
            subpoolData.isFrozen = true;
            subPoolData[pool] = subpoolData;
        } else {
            revert SubPoolFactory__FreezeTimestampNotElapsedYet();
        }
    }

    /// @notice Thaw `pool` if they are above collateralization requirements.
    function thaw(address pool) external {
        SubPoolData memory subpoolData = subPoolData[pool];
        // thaw the pool if it is over collateralized again
        if (_checkCollateralization(pool, subpoolData)) {
            subpoolData.freezeTimestamp = 0;
            subpoolData.isFrozen = false;
            subPoolData[pool] = subpoolData;
            return;
        }
        revert SubPoolFactory__CannotThaw();
    }

    /// @notice signal the intent to quit.
    function quitPool() external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp != 0) revert SubPoolFactory__PoolAlreadyQuit();
        subPoolData[pool].exitTimestamp = uint104(block.timestamp + cfg.exitDelay);
    }

    /// @notice exit the pool.
    function exitPool() external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp == 0) revert SubPoolFactory__PoolHasNotQuitYet();
        if (subpoolData.exitTimestamp > block.timestamp) revert SubPoolFactory__ExitDelayNotElapsed();
        if (subpoolData.hasExited) revert SubPoolFactory__PoolAlreadyExited();
        subPoolData[pool].hasExited = true;
    }

    function exitTimestamp(address pool) external view returns (uint256) {
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        return subpoolData.exitTimestamp;
    }

    function dues(address pool) external view returns (uint256 amt, uint256 cowAmt) {
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp != 0) return (0, 0);
        Config memory config = cfg;
        uint256 minTokenAmt = _tokenAmt(subpoolData.collateral, config.minUsdAmt);
        uint256 minCowAmt = config.minCowAmt;
        uint256 tokenBalance = ERC20(subpoolData.collateral).balanceOf(pool);
        uint256 cowBalance = ERC20(COW).balanceOf(pool);
        return (
            minTokenAmt > tokenBalance ? minTokenAmt - tokenBalance : 0,
            minCowAmt > cowBalance ? minCowAmt - cowBalance : 0
        );
    }

    /// @notice Determine whether a given token is a valid collateral token.
    function collateral(address token) external view returns (bool) {
        return address(priceFeeds[token]) != address(0);
    }

    /// @notice Determine if the pool is a valid solver.
    function isSolver(address pool) external view returns (bool) {
        SubPoolData memory subpoolData = subPoolData[pool];
        // check first if the pool exists
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        // all pools that have not yet exited, not currently frozen and not yet quit are solvers.
        // poked pools are also still solvers until frozen i.e. freeze delay has passed.
        return !subpoolData.hasExited && !subpoolData.isFrozen && subpoolData.exitTimestamp == 0;
    }

    /// @notice pool address for given user computed deterministically.
    function poolOf(address usr) external view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(SubPool).creationCode, abi.encode(usr, COW)));
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", address(this), bytes32(uint256(uint160(usr))), initCodeHash))
                )
            )
        );
    }

    function _checkCollateralization(address pool, SubPoolData memory subpoolData) internal view returns (bool) {
        Config memory config = cfg;
        address token = subpoolData.collateral;
        uint256 tokenBalance = ERC20(token).balanceOf(pool);
        uint256 cowBalance = ERC20(COW).balanceOf(pool);
        return _usdValue(token, tokenBalance) >= config.minUsdAmt && cowBalance >= config.minCowAmt;
    }

    function _updateCollateralFeed(address token, address feed) internal {
        priceFeeds[token] = IAggregatorV3Interface(feed);
        emit UpdateCollateral(token, feed);
    }

    function _usdValue(address token, uint256 amt) internal view returns (uint256) {
        IAggregatorV3Interface priceFeed = priceFeeds[token];
        if (address(priceFeed) == address(0)) revert SubPoolFactory__UnauthorizedCollateral();
        uint8 decimals = ERC20(token).decimals();
        uint256 oneToken = 10 ** decimals;

        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer < 0) revert SubPoolFactory__InvalidPrice();
        uint8 priceDecimals = priceFeed.decimals();
        uint256 numerator = USD_DECIMALS > priceDecimals ? 10 ** (USD_DECIMALS - priceDecimals) : 1;
        uint256 denominator = USD_DECIMALS < priceDecimals ? 10 ** (priceDecimals - USD_DECIMALS) : 1;

        return (amt * uint256(answer) * numerator) / (denominator * oneToken);
    }

    function _tokenAmt(address token, uint256 usdAmt) internal view returns (uint256) {
        IAggregatorV3Interface priceFeed = priceFeeds[token];
        if (address(priceFeed) == address(0)) revert SubPoolFactory__UnauthorizedCollateral();
        uint8 decimals = ERC20(token).decimals();
        uint256 oneToken = 10 ** decimals;

        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer < 0) revert SubPoolFactory__InvalidPrice();
        uint8 priceDecimals = priceFeed.decimals();
        uint256 price = priceDecimals > USD_DECIMALS
            ? uint256(answer) / (10 ** (priceDecimals - USD_DECIMALS))
            : (uint256(answer) * 10 ** (USD_DECIMALS - priceDecimals));

        return oneToken * usdAmt / price;
    }

    function _poke(address pool, bool shouldRevert) internal {
        SubPoolData memory subpoolData = subPoolData[pool];
        // only set freezeTimestamp if it is not already set and if it is under collateralized
        if (subpoolData.freezeTimestamp == 0 && !_checkCollateralization(pool, subpoolData)) {
            subPoolData[pool].freezeTimestamp = uint104(block.timestamp + cfg.freezeDelay);
            return;
        }
        if (shouldRevert) {
            revert SubPoolFactory__CannotPoke();
        }
    }
}
