pragma solidity 0.8.26;

import {SubPoolFactory, Auth, SubPool} from "src/SubPoolFactory.sol";
import {MockToken} from "./MockToken.sol";
import {TOKEN_WETH_MAINNET, TOKEN_COW_MAINNET} from "src/constants.sol";
import {BaseTest} from "./BaseTest.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract SubPoolFactoryTest is BaseTest {
    MockToken lst = new MockToken("LST", "ether");
    address solver = makeAddr("solver");
    address solverPoolAddress;
    uint256 solverEthAmt = 20 ether;
    uint256 solverCowAmt = 100_000 ether;
    SubPool solverPool;
    address notOwner = makeAddr("notOwner");
    string backendUri = "https://backend.solver.com";

    function setUp() public override {
        super.setUp();

        solverPoolAddress = _seedAndDeployPool(solver, TOKEN_WETH_MAINNET, solverEthAmt, solverCowAmt, 0, backendUri);
        solverPool = SubPool(solverPoolAddress);
    }

    function testCreate() external {
        address user = makeAddr("user");

        // if amts are correct, but user doesnt have the tokens, revert
        vm.expectRevert();
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 15 ether, solverCowAmt, backendUri);

        // give tokens to the user
        deal(TOKEN_WETH_MAINNET, user, 15 ether);
        deal(TOKEN_COW_MAINNET, user, solverCowAmt);
        vm.startPrank(user);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), 15 ether);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), solverCowAmt);
        address userPool = factory.create(TOKEN_WETH_MAINNET, 15 ether, solverCowAmt, backendUri);
        vm.stopPrank();

        (address collateral, uint176 exitTimestamp) = factory.subPoolData(solverPoolAddress);
        assertEq(collateral, TOKEN_WETH_MAINNET, "collateral not as expected");
        assertEq(exitTimestamp, 0, "exit timestamp should be initialized to 0");
        assertEq(factory.backendUri(solverPoolAddress), backendUri, "solver backend uri not set at initialization");

        // pool creator should become a member of its own pool by default
        assertEq(factory.solverBelongsTo(user), userPool, "pool creator should be a member of its own pool");
    }

    function testPoolOf() external view {
        address expectedSolverPool = factory.poolOf(solver);
        assertEq(expectedSolverPool, solverPoolAddress, "solver pool address not as expected");
    }

    function testSubPool() external {
        address expectedSolverPool = factory.solverSubPool(solver);
        assertEq(expectedSolverPool, solverPoolAddress, "solver pool address not as expected");
        address anotherSolver = makeAddr("anotherSolver");
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.solverSubPool(anotherSolver);
    }

    function testSubPoolData() external {
        (address collateral, uint176 exitTs) = factory.subPoolData(solverPoolAddress);
        assertEq(collateral, TOKEN_WETH_MAINNET, "collateral not as expected");
        assertEq(exitTs, 0, "exit timestamp not as expected");

        vm.prank(solver);
        solverPool.announceExit();
        (, exitTs) = factory.subPoolData(solverPoolAddress);
        assertEq(exitTs, block.timestamp + exitDelay, "exit timestamp not as expected");
    }

    function testBill() external {
        // only relied users can fine
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.bill(solverPoolAddress, 1 ether, 10000 ether, 0.1 ether, "billing reason");

        vm.deal(solverPoolAddress, 1 ether);
        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        uint256 cowBalanceBefore = cow.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;
        uint256 wethFined = 0.1 ether;
        uint256 cowFined = 10 ether;
        uint256 ethFined = 0.01 ether;
        factory.bill(solverPoolAddress, wethFined, cowFined, ethFined, "testing bill");

        assertEq(weth.balanceOf(address(this)) - wethBalanceBefore, wethFined, "weth not fined as expected");
        assertEq(cow.balanceOf(address(this)) - cowBalanceBefore, cowFined, "cow not fined as expected");
        assertEq(address(this).balance - ethBalanceBefore, ethFined, "eth not fined as expected");
        (, uint176 exitTimestamp) = factory.subPoolData(solverPoolAddress);
        assertEq(exitTimestamp, 0, "pool shouldn't have announced exit yet");

        // bill should work in exit period
        vm.prank(solver);
        solverPool.announceExit();

        ethBalanceBefore = address(this).balance;
        factory.bill(solverPoolAddress, 0, 0, 1, "billing in exit period");
        assertEq(address(this).balance - ethBalanceBefore, 1, "didnt bill as expected");

        // bill shouldn't work after the exit delay has elapsed
        ethBalanceBefore = address(this).balance;
        (, exitTimestamp) = factory.subPoolData(solverPoolAddress);
        vm.warp(exitTimestamp);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__CannotBillAfterExitDelay.selector);
        factory.bill(solverPoolAddress, 0, 0, 1, "billing after exit delay");
    }

    function testSetExitDelay() external {
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.setExitDelay(1);

        factory.setExitDelay(1);
        uint256 exitDelay = factory.exitDelay();
        assertEq(exitDelay, 1, "exit delay not set as expected");
    }

    function testExitTimestamp() external {
        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "pool hasnt exited yet");

        // announce exit for the pool
        vm.prank(solverPoolAddress);
        factory.announceExit();
        uint256 exitTs = block.timestamp + exitDelay;
        assertEq(factory.exitTimestamp(solverPoolAddress), exitTs, "exit timestamp not as expected");
    }

    function testAnnounceExit() external {
        // addresses not spawned by the factory's create method shouldn't be able to
        // call announceExit
        vm.prank(notOwner);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.announceExit();

        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "no exit timestamp before announce exit");
        vm.prank(solverPoolAddress);
        factory.announceExit();
        assertEq(
            factory.exitTimestamp(solverPoolAddress),
            block.timestamp + exitDelay,
            "exit timestamp not set by announce exit"
        );

        // pool cannot announce exit twice
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolAlreadyAnnouncedExit.selector);
        factory.announceExit();
    }

    function testUpdateBackendUri() external {
        assertEq(factory.backendUri(solverPoolAddress), backendUri, "backend uri not as expected");
        string memory newBackendUri = "https://new-backend.solver.com";
        vm.prank(solver);
        solverPool.updateBackendUri(newBackendUri);
        assertEq(factory.backendUri(solverPoolAddress), newBackendUri);
    }

    function testCanSolve() external {
        address anotherSolver = makeAddr("anotherSolver");
        vm.prank(solver);
        solverPool.updateSolverMembership(anotherSolver, true);

        assertEq(factory.canSolve(solver), true, "pool owner be a solver");
        assertEq(factory.canSolve(anotherSolver), true, "pool member should be a solver");

        vm.deal(solverPoolAddress, 1 ether);
        factory.bill(solverPoolAddress, 0, 0, 1, "pool shouldnt be a solver if there are dues");
        assertEq(factory.canSolve(solver), false, "pool owner shouldnt be a solver");
        assertEq(factory.canSolve(anotherSolver), false, "pool member shouldn't be a solver");

        // pay the dues and that should restore solvability
        solverPool.heal{value: 1}();
        assertEq(factory.canSolve(solver), true, "pool owner should be a solver again after the pool is healed");
        assertEq(factory.canSolve(anotherSolver), true, "pool member should be a solver again after the pool is healed");

        // announce exit
        vm.prank(solverPoolAddress);
        factory.announceExit();
        assertEq(factory.canSolve(solver), false, "announced exited pools' owner shouldnt be a solver");
        assertEq(factory.canSolve(anotherSolver), false, "announced exited pools' members shouldnt be a solver");

        // uninited pools should revert
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.canSolve(makeAddr("someUninitedpool"));
    }

    function testFastTrackExit() external {
        // only owners
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.fastTrackExit(solverPoolAddress, uint88(block.timestamp));

        // only known pools
        address randomPool = makeAddr("randomPool");
        require(randomPool.code.length == 0);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.fastTrackExit(randomPool, uint88(block.timestamp));

        // only pools that have announced an exit
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolHasNotAnnouncedExitYet.selector);
        factory.fastTrackExit(solverPoolAddress, uint88(block.timestamp));

        // exit timestamp can only be reduced
        vm.prank(solver);
        solverPool.announceExit();
        uint256 exitTs = factory.exitTimestamp(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__InvalidFastTrackExit.selector);
        factory.fastTrackExit(solverPoolAddress, uint88(exitTs + 1));

        uint256 newExitTs = exitTs - 100;
        factory.fastTrackExit(solverPoolAddress, uint88(newExitTs));
        assertEq(factory.exitTimestamp(solverPoolAddress), newExitTs, "new exit timestamp not as expected");
    }

    function testUpdateSolverMembership() external {
        address notPool = makeAddr("notPool");
        address newSolver = makeAddr("newSolver");

        // only subpools can call this
        vm.prank(notPool);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.updateSolverMembership(newSolver, true);

        // can only add a solver that does not already have a pool of its own
        address anotherSolver = makeAddr("anotherSolver");
        address anotherSolverPool = _seedAndDeployPool(
            anotherSolver, TOKEN_WETH_MAINNET, 1 ether, solverCowAmt, 0, "https://backend.anothersolver.com"
        );
        vm.prank(solver);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__SolverHasActiveMembership.selector);
        solverPool.updateSolverMembership(anotherSolver, true);

        // can only add a solver that does not already belong to some other pool
        address thirdSolver = makeAddr("thirdSolver");
        vm.prank(anotherSolver);
        SubPool(anotherSolverPool).updateSolverMembership(thirdSolver, true);

        vm.prank(solver);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__SolverHasActiveMembership.selector);
        solverPool.updateSolverMembership(thirdSolver, true);

        // can only remove solver of your own pool
        vm.prank(solver);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__SolverNotAMember.selector);
        solverPool.updateSolverMembership(thirdSolver, false);
    }

    receive() external payable {}
}
