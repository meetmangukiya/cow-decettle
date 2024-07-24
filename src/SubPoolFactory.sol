// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Auth} from "./Auth.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SubPool} from "./SubPool.sol";
import {ISubPoolFactory} from "./interfaces/ISubPoolFactory.sol";

contract SubPoolFactory is Auth, ISubPoolFactory {
    error SubPoolFactory__InsufficientCollateral();
    error SubPoolFactory__UnknownPool();
    error SubPoolFactory__ExitDelayNotElapsed();
    error SubPoolFactory__PoolHasNotAnnouncedExitYet();
    error SubPoolFactory__PoolAlreadyAnnouncedExit();
    error SubPoolFactory__PoolAlreadyExited();
    error SubPoolFactory__InvalidFastTrackExit();
    error SubPoolFactory__CannotBillAfterExitDelay();

    event UpdateExitDelay(uint256 newDelay);
    event UpdateMinCowAmt(uint256 amt);
    event UpdateBackendUri(address indexed pool, string uri);
    event SolverPoolDeployed(address indexed solver, address indexed pool);
    event SolverPoolBilled(address indexed pool, uint256 amt, uint256 cowAmt, uint256 ethAmt, string reason);
    event AnnounceExit(address indexed pool);
    event Exit(address indexed pool);

    struct SubPoolData {
        /// The collateral token that pool was initialized with.
        address collateral;
        /// The timestamp at which the pool can exit.
        uint88 exitTimestamp;
        /// Whether the pool has exited.
        bool hasExited;
    }

    /// @notice Individual subpool data
    mapping(address => SubPoolData) public subPoolData;
    /// @notice Solver backend uri
    /// @dev    Not stored in the SubPoolData because we don't want to load the string
    ///         everytime we read the subpooldata in memory.
    mapping(address => string) public backendUri;
    /// @notice the delay between `announceExit` and `exit`.
    uint256 public exitDelay;
    /// @notice the minimum amount of COW to be bonded.
    uint256 public minCowAmt;
    address public immutable COW;

    constructor(uint256 exitDelay_, uint256 minCowAmt_, address cow) {
        exitDelay = exitDelay_;
        minCowAmt = minCowAmt_;
        emit UpdateExitDelay(exitDelay);
        emit UpdateMinCowAmt(minCowAmt);
        COW = cow;
        _addOwner(msg.sender);
    }

    /// @notice Set the delay between `announceExit` and `exitPool`.
    function setExitDelay(uint32 delay) external auth {
        exitDelay = delay;
        emit UpdateExitDelay(delay);
    }

    /// @notice Set the min cow amount.
    function setMinCowAmt(uint224 amt) external auth {
        minCowAmt = amt;
        emit UpdateMinCowAmt(amt);
    }

    /// @notice Create a `SubPool` for the user at a deterministic address with salt as `msg.sender`.
    /// @param token  - The token to use as collateral.
    function create(address token, uint256 amt, uint256 cowAmt, string calldata uri) external returns (address) {
        SubPool subpool = new SubPool{salt: bytes32(0)}(msg.sender, COW);
        subpool.initializeCollateralToken(token);
        emit SolverPoolDeployed(msg.sender, address(subpool));

        if (cowAmt < minCowAmt) {
            revert SubPoolFactory__InsufficientCollateral();
        }

        subPoolData[address(subpool)] = SubPoolData({collateral: token, exitTimestamp: 0, hasExited: false});
        backendUri[address(subpool)] = uri;
        emit UpdateBackendUri(address(subpool), uri);

        SafeTransferLib.safeTransferFrom(token, msg.sender, address(subpool), amt);
        SafeTransferLib.safeTransferFrom(COW, msg.sender, address(subpool), cowAmt);

        return address(subpool);
    }

    /// @notice Bill a subpool
    /// @param pool   - The subpool to bill.
    /// @param amt    - Amount of pool's collateralToken to bill.
    /// @param cowAmt - Amount of COW to bill.
    /// @param ethAmt - Amount of ETH to bill.
    /// @param reason - Reason for bill (e.g. fees, fine etc).
    function bill(address pool, uint256 amt, uint256 cowAmt, uint256 ethAmt, string calldata reason) external auth {
        // verify that the pool's exit delay has not elapsed if it was requested.
        uint256 exitTs = subPoolData[pool].exitTimestamp;
        if (exitTs != 0 && block.timestamp >= exitTs) revert SubPoolFactory__CannotBillAfterExitDelay();

        SubPool(pool).bill(amt, cowAmt, ethAmt, msg.sender);
        emit SolverPoolBilled(pool, amt, cowAmt, ethAmt, reason);
    }

    /// @notice Announce the intent to exit solving batch auctions.
    function announceExit() external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp != 0) revert SubPoolFactory__PoolAlreadyAnnouncedExit();
        subPoolData[pool].exitTimestamp = uint88(block.timestamp + exitDelay);
        emit AnnounceExit(pool);
    }

    /// @notice Exit the pool.
    function exitPool() external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp == 0) revert SubPoolFactory__PoolHasNotAnnouncedExitYet();
        if (subpoolData.exitTimestamp > block.timestamp) revert SubPoolFactory__ExitDelayNotElapsed();
        if (subpoolData.hasExited) revert SubPoolFactory__PoolAlreadyExited();
        subPoolData[pool].hasExited = true;
        emit Exit(pool);
    }

    /// @notice Update solver's backend uri.
    function updateBackendUri(string calldata uri) external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        backendUri[pool] = uri;
        emit UpdateBackendUri(pool, uri);
    }

    /// @notice Override the exit timestamp to allow for an earlier exit.
    function fastTrackExit(address pool, uint88 newExitTimestamp) external auth {
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        if (subpoolData.exitTimestamp == 0) revert SubPoolFactory__PoolHasNotAnnouncedExitYet();
        if (subpoolData.hasExited) revert SubPoolFactory__PoolAlreadyExited();
        if (newExitTimestamp > subpoolData.exitTimestamp) revert SubPoolFactory__InvalidFastTrackExit();
        subpoolData.exitTimestamp = newExitTimestamp;
        subPoolData[pool] = subpoolData;
    }

    /// @notice Determine if the solver can submit solutions.
    function canSolve(address solver) external view returns (bool) {
        address pool = poolOf(solver);
        SubPoolData memory subpoolData = subPoolData[pool];
        // check first if the pool exists
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        // all pools that have not yet exited, not currently frozen and not yet quit are solvers.
        // poked pools are also still solvers until frozen i.e. freeze delay has passed.

        // cannot solve if exited or announced exit
        if (subpoolData.exitTimestamp != 0) {
            return false;
        }

        // cannot solve if there are any pending dues
        (uint256 amt, uint256 cowAmt, uint256 ethAmt) = SubPool(pool).dues();
        return amt == 0 && cowAmt == 0 && ethAmt == 0;
    }

    /// @notice Read subpool's exit timestamp.
    function exitTimestamp(address pool) external view returns (uint256) {
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        return subpoolData.exitTimestamp;
    }

    /// @notice Read solver's subpool address.
    /// @dev    Only difference from `poolOf` is this checks if the subpool has been initialized.
    function solverSubPool(address solver) public view returns (address) {
        address pool = poolOf(solver);
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();
        return pool;
    }

    /// @notice pool address for given user computed deterministically.
    function poolOf(address usr) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(SubPool).creationCode, abi.encode(usr, COW)));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), bytes32(0), initCodeHash)))));
    }
}
