// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Auth} from "./Auth.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SubPool} from "./SubPool.sol";
import {ISubPoolFactory} from "./interfaces/ISubPoolFactory.sol";

using SafeTransferLib for address;

contract SubPoolFactory is Auth, ISubPoolFactory {
    error SubPoolFactory__UnknownPool();
    error SubPoolFactory__ExitDelayNotElapsed();
    error SubPoolFactory__PoolHasNotAnnouncedExitYet();
    error SubPoolFactory__PoolAlreadyAnnouncedExit();
    error SubPoolFactory__PoolAlreadyExited();
    error SubPoolFactory__InvalidFastTrackExit();
    error SubPoolFactory__CannotBillAfterExitDelay();
    error SubPoolFactory__SolverHasActiveMembership();
    error SubPoolFactory__SolverNotAMember();

    event UpdateExitDelay(uint256 newDelay);
    event UpdateBackendUri(address indexed pool, string uri);
    event SolverPoolDeployed(address indexed solver, address indexed pool);
    event SolverPoolBilled(address indexed pool, uint256 amt, uint256 cowAmt, uint256 ethAmt, string reason);
    event AnnounceExit(address indexed pool);
    event Exit(address indexed pool);
    event UpdateSolverMembership(address indexed pool, address indexed solver, bool isMember);

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
    /// @notice One to one mappping of solver to a subpool.
    /// @dev    If a solver already has a subpool of their own, they cannot belong to any other pool.
    ///         If a solver belongs to some pool, they cannot deploy their own subpool unless they are
    ///         removed from the solver subpool.
    mapping(address => address) public solverBelongsTo;
    /// @notice the delay between `announceExit` and `exit`.
    uint256 public exitDelay;
    address public immutable COW;

    constructor(uint256 exitDelay_, address cow) {
        exitDelay = exitDelay_;
        emit UpdateExitDelay(exitDelay);
        COW = cow;
        _addOwner(msg.sender);
    }

    /// @notice Set the delay between `announceExit` and `exitPool`.
    function setExitDelay(uint32 delay) external auth {
        exitDelay = delay;
        emit UpdateExitDelay(delay);
    }

    /// @notice Create a `SubPool` for the user at a deterministic address with salt as `msg.sender`.
    /// @param token  - The token to use as collateral.
    function create(address token, uint256 amt, uint256 cowAmt, string calldata uri) external returns (address) {
        SubPool subpool = new SubPool{salt: bytes32(0)}(msg.sender, COW);
        subpool.initializeCollateralToken(token);
        emit SolverPoolDeployed(msg.sender, address(subpool));

        subPoolData[address(subpool)] = SubPoolData({collateral: token, exitTimestamp: 0, hasExited: false});
        backendUri[address(subpool)] = uri;
        emit UpdateBackendUri(address(subpool), uri);

        // the pool creator becomes a member of its pool by default so it doesn't require another
        // manual transaction to set oneself as solver
        solverBelongsTo[msg.sender] = address(subpool);
        emit UpdateSolverMembership(address(subpool), msg.sender, true);

        COW.safeTransferFrom(msg.sender, address(subpool), cowAmt);
        token.safeTransferFrom(msg.sender, address(subpool), amt);

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

    /// @notice Update solver membership.
    function updateSolverMembership(address solver, bool add) external {
        address pool = msg.sender;
        SubPoolData memory subpoolData = subPoolData[pool];
        if (subpoolData.collateral == address(0)) revert SubPoolFactory__UnknownPool();

        if (add) {
            // check if solver has a membership of some other pool
            if (solverBelongsTo[solver] != address(0)) revert SubPoolFactory__SolverHasActiveMembership();
            solverBelongsTo[solver] = pool;
            emit UpdateSolverMembership(pool, solver, true);
        } else {
            // check that the solver is member of the given pool
            if (solverBelongsTo[solver] != pool) revert SubPoolFactory__SolverNotAMember();
            solverBelongsTo[solver] = address(0);
            emit UpdateSolverMembership(pool, solver, false);
        }
    }

    /// @notice Leave a subpool membership.
    /// @dev    This is important to prevent DoS and preventing solver from creating their own pool.
    function leaveSubPool() external {
        address pool = solverBelongsTo[msg.sender];
        solverBelongsTo[msg.sender] = address(0);
        emit UpdateSolverMembership(pool, msg.sender, false);
    }

    /// @notice Determine if the solver can submit solutions.
    function canSolve(address solver) external view returns (bool) {
        address pool = solverBelongsTo[solver];

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
