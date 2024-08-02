pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SubPool, ISubPoolFactory, Auth} from "src/SubPool.sol";
import {MockToken, ERC20} from "./MockToken.sol";
import {SubPoolFactory} from "src/SubPoolFactory.sol";

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

    function testDues() external {
        vm.deal(solverPoolAddress, ethAmtDue);

        factory.bill(solverPoolAddress, amtDue, cowAmtDue, ethAmtDue, "billed amount should reflect in dues");

        (uint256 amt, uint256 cowAmt, uint256 ethAmt_) = pool.dues();
        assertEq(amt, amtDue, "token amt due is incorrect");
        assertEq(cowAmt, cowAmtDue, "cow token amt due is incorrect");
        assertEq(ethAmt_, ethAmtDue, "eth amt due is incorrect");
    }

    function testHeal() external {
        // create some dues
        factory.bill(solverPoolAddress, amtDue, cowAmtDue, ethAmtDue, "create some dues for the test");

        // anyone can heal
        address user = makeAddr("user");
        assertEq(pool.isOwner(user), false, "user is a owner");

        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(pool));
        uint256 cowBalanceBefore = COW.balanceOf(address(pool));
        uint256 ethBalanceBefore = solverPoolAddress.balance;

        deal(address(collateralToken), user, amtDue);
        deal(address(COW), user, cowAmtDue);
        vm.deal(user, ethAmtDue);

        vm.startPrank(user);
        collateralToken.approve(address(pool), amtDue);
        COW.approve(address(pool), cowAmtDue);
        pool.heal{value: ethAmtDue}();
        vm.stopPrank();

        assertEq(
            collateralToken.balanceOf(address(pool)),
            collateralBalanceBefore + amtDue,
            "heal did not transfer the tokens"
        );
        assertEq(COW.balanceOf(address(pool)), cowBalanceBefore + cowAmtDue, "heal did not transfer the tokens");
        assertEq(solverPoolAddress.balance, ethBalanceBefore + ethAmtDue, "heal did not transfer enough eth");
        (uint256 amtDue_, uint256 cowAmtDue_, uint256 ethAmtDue_) = pool.dues();
        assertEq(amtDue_, 0, "collateral dues should be 0 after healing");
        assertEq(cowAmtDue_, 0, "cow dues should be 0 after healing");
        assertEq(ethAmtDue_, 0, "eth dues should be 0 after healing");
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

        // shouldnt be able to withdraw collateral token or COW
        address[] memory tks = new address[](1);
        tks[0] = address(collateralToken);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        tks[0] = address(COW);
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

        // cannot withdraw cow and collateral before exitTs
        vm.warp(exitTs - 1);
        tks[0] = address(COW);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);
        tks[0] = address(collateralToken);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        vm.warp(exitTs);
        tks[0] = address(collateralToken);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(collateralToken.balanceOf(anotherOwner), 1 ether, "collateral token balance not as expected");
        assertEq(anotherOwner.balance, ethDealt, "ether balance not as expected");
        tks[0] = address(COW);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(COW.balanceOf(anotherOwner), 10 ether, "COW balance not as expected");
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
