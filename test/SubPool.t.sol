pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {SubPool, ISubPoolFactory, Auth} from "src/SubPool.sol";
import {MockToken, ERC20} from "./MockToken.sol";
import {SubPoolFactory} from "src/SubPoolFactory.sol";
import {TOKEN_NATIVE_ETH} from "src/constants.sol";

contract SubPoolTest is Test {
    SubPool pool;
    MockToken collateralToken;
    MockToken COW;
    MockToken mockToken;
    SubPoolFactory factory;
    uint256 amtDue = 1 ether;
    uint256 cowAmtDue = 10 ether;
    uint256 ethAmtDue = 5 ether;
    uint32 exitDelay = 1 days;
    uint224 minCowAmt = 10000 ether;
    uint256 collateralAmt = 100 ether;
    uint256 ethAmt = 10 ether;
    address solverPoolAddress;

    function setUp() external {
        collateralToken = new MockToken("Collateral", "CLT");
        vm.label(address(collateralToken), "CLT");
        COW = new MockToken("COW", "COW");
        vm.label(address(COW), "COW");
        mockToken = new MockToken("MTK", "MTK");
        vm.label(address(mockToken), "MTK");
        factory = new SubPoolFactory(exitDelay, address(COW), address(this));

        deal(address(COW), address(this), minCowAmt);
        deal(address(collateralToken), address(this), collateralAmt);
        collateralToken.approve(address(factory), collateralAmt);
        COW.approve(address(factory), minCowAmt);

        pool = SubPool(
            payable(factory.create(address(collateralToken), collateralAmt, minCowAmt, "https://backend.solver.com"))
        );
        solverPoolAddress = address(pool);
        vm.deal(solverPoolAddress, ethAmt);
    }

    function testAnnounceExit() external {
        // pool should notify the factory
        vm.expectCall(address(factory), abi.encodeCall(ISubPoolFactory.announceExit, ()));
        pool.announceExit();

        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        vm.prank(makeAddr("user"));
        pool.announceExit();
    }

    function testBill() external {
        deal(address(collateralToken), address(pool), 1 ether);
        deal(address(COW), address(pool), 10 ether);
        vm.deal(address(pool), 0.1 ether);

        address receiver = makeAddr("receiver");
        vm.prank(address(factory));
        pool.bill(0.1 ether, 1 ether, 0.01 ether, receiver);

        assertEq(collateralToken.balanceOf(receiver), 0.1 ether, "bill didnt transfer tokens as expected");
        assertEq(COW.balanceOf(receiver), 1 ether, "bill didnt transfer tokens as expected");
        assertEq(receiver.balance, 0.01 ether, "bill didnt transfer eth as expected");

        vm.expectRevert(SubPool.SubPool__OnlyFactory.selector);
        pool.bill(0.1 ether, 1 ether, 0.01 ether, receiver);
    }

    function testWithdrawTokens() external {
        deal(address(collateralToken), address(pool), 1 ether);
        deal(address(COW), address(pool), 10 ether);
        deal(address(mockToken), address(pool), 1 ether);
        uint256 ethDealt = 0.1 ether;
        vm.deal(address(pool), ethDealt);

        // shouldnt be able to withdraw collateral token, ETH or COW
        address[] memory tks = new address[](1);
        tks[0] = address(collateralToken);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        tks[0] = address(COW);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        tks[0] = TOKEN_NATIVE_ETH;
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        // only owner can withdraw
        tks[0] = address(mockToken);
        vm.prank(makeAddr("user"));
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        pool.withdrawTokens(tks);

        address anotherOwner = makeAddr("anotherOwner");
        pool.addOwner(anotherOwner);

        // tokens are sent to the calling owner
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(mockToken.balanceOf(anotherOwner), 1 ether, "MTK balance not as expected");
        assertEq(address(pool).balance, ethDealt, "ETH shouldn't be withdrawn before exit has elapsed");

        // after exit it should be able to withdraw any tokens.
        pool.announceExit();
        uint256 exitTs = factory.exitTimestamp(address(pool));

        // cannot withdraw cow, eth or collateral before exitTs
        vm.warp(exitTs - 1);
        tks[0] = address(COW);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);
        tks[0] = address(collateralToken);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);
        tks[0] = TOKEN_NATIVE_ETH;
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        vm.warp(exitTs);
        tks[0] = address(collateralToken);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(collateralToken.balanceOf(anotherOwner), 1 ether, "collateral token balance not as expected");
        tks[0] = address(COW);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(COW.balanceOf(anotherOwner), 10 ether, "COW balance not as expected");
        assertEq(anotherOwner.balance, 0, "another owner balance should be 0");
        tks[0] = TOKEN_NATIVE_ETH;
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(anotherOwner.balance, 0.1 ether, "ether balance not as expected");
    }

    function testUpdateSolverMembership() external {
        address newSolver = makeAddr("newSolver");
        address anotherOwner = makeAddr("anotherOwner");
        pool.addOwner(anotherOwner);
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        pool.updateSolverMembership(newSolver, true);

        vm.prank(anotherOwner);
        vm.expectCall(address(factory), abi.encodeCall(factory.updateSolverMembership, (newSolver, true)));
        pool.updateSolverMembership(newSolver, true);

        vm.prank(anotherOwner);
        vm.expectCall(address(factory), abi.encodeCall(factory.updateSolverMembership, (newSolver, false)));
        pool.updateSolverMembership(newSolver, false);
    }

    function testReceiveEth() external {
        uint256 prevBalance = address(pool).balance;
        (bool success,) = address(pool).call{value: 1 ether}("");
        require(success);
        assertEq(address(pool).balance, prevBalance + 1 ether);
    }

    function testUpdateBackendUri() external {
        string memory newUri = "https://backend2.solver.com";

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        pool.updateBackendUri(newUri);

        address anotherOwner = makeAddr("anotherOwner");
        pool.addOwner(anotherOwner);

        vm.prank(anotherOwner);
        vm.expectCall(address(factory), abi.encodeCall(factory.updateBackendUri, (newUri)));
        pool.updateBackendUri(newUri);
    }

    receive() external payable {}
}
