import {Test} from "forge-std/Test.sol";
import {Auth} from "src/Auth.sol";

contract AuthImpl is Auth {
    constructor() {
        _addOwner(msg.sender);
    }

    function authedCall() external auth {}
}

contract AuthTest is Test {
    AuthImpl auth;
    address notOwner = makeAddr("notOwner");

    function setUp() external {
        auth = new AuthImpl();
    }

    function testAddOwner() external {
        address anotherOwner = makeAddr("anotherOwner");
        assertFalse(auth.isOwner(anotherOwner), "anotherOwner shouldnt be an owner");

        // only owner can add new owners
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        auth.addOwner(anotherOwner);

        auth.addOwner(anotherOwner);
        assertTrue(auth.isOwner(anotherOwner), "anotherOwner should be an owner");
    }

    function testRemoveOwner() external {
        address anotherOwner = makeAddr("anotherOwner");
        auth.addOwner(anotherOwner);
        assertTrue(auth.isOwner(anotherOwner), "anotherOwner should be an owner");

        // only owners can remove existing owner
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        auth.removeOwner(anotherOwner);

        auth.removeOwner(anotherOwner);
        assertFalse(auth.isOwner(anotherOwner), "anotherOwner shouldnt be an owner");
    }

    function testAuthModifier() external {
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        auth.authedCall();

        address anotherOwner = makeAddr("anotherOwner");
        auth.addOwner(anotherOwner);
        // shouldnt revert
        auth.authedCall();
    }
}
