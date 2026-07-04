// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EchoSpendRouter} from "../src/examples/EchoSpendRouter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

contract EchoSpendRouterHappyPathTest is Test {
    MockERC20Permit token;
    EchoSpendRouter router;
    address anchor = address(0xA4C402);
    uint256 userPk = 0xA11CE;
    address user;
    bytes32 constant TOPIC = keccak256("echo-topic");

    function setUp() public {
        token = new MockERC20Permit();
        router = new EchoSpendRouter(address(token), anchor, address(0));
        user = vm.addr(userPk);
        token.mint(user, 100e6);
    }

    function test_views() public view {
        assertEq(router.token(), address(token));
        assertEq(router.anchor(), anchor);
        assertEq(router.delegationManager(), address(0));
        assertEq(router.routerType(), keccak256("ECHO_SPEND_ROUTER"));
        assertEq(router.version(), "0.1.0");
        assertFalse(router.orderConsumed(keccak256("nope")));
    }

    function test_pay_moves_funds_to_bound_destination() public {
        address dest = router.destinationFor(TOPIC, user);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        router.pay(TOPIC, 25e6, keccak256("order-1"));
        vm.stopPrank();
        assertEq(token.balanceOf(dest), 25e6);
        assertEq(token.balanceOf(user), 75e6);
        assertTrue(router.orderConsumed(keccak256("order-1")));
    }

    function test_pay_with_permit_moves_funds() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                token.PERMIT_TYPEHASH(), user, address(router), 25e6, token.nonces(user), deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        router.payWithPermit(TOPIC, 25e6, keccak256("order-p"), user, deadline, v, r, s);
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 25e6);
    }
}
