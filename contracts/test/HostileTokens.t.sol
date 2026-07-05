// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {EchoSpendRouter} from "../src/examples/EchoSpendRouter.sol";
import {
    ReturnFalseToken,
    FeeOnTransferToken,
    BonusToken,
    NoReturnToken,
    ReentrantToken
} from "./mocks/HostileTokens.sol";

/// @notice Pins _routeSpend's behavior under hostile tokens (spec §8, router
///         invariants row). USDC is none of these; the point is that a wrong
///         token config degrades to a clean atomic revert — never a silent
///         partial spend — and that a reentrant token cannot interleave a
///         nested spend (reentrancy lock).
contract HostileTokensTest is Test {
    address anchor = address(0xA4C402);
    address user = address(0xA11CE7);
    bytes32 constant TOPIC = keccak256("echo-topic");

    function test_return_false_token_reverts_atomically() public {
        ReturnFalseToken token = new ReturnFalseToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-1"));
        vm.stopPrank();
        // Post-revert state is fully intact: balances unmoved, order unconsumed.
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertFalse(router.orderConsumed(keccak256("hostile-1")));
    }

    function test_fee_on_transfer_token_reverts_atomically() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-2"));
        vm.stopPrank();
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 0);
        assertFalse(router.orderConsumed(keccak256("hostile-2")));
    }

    function test_bonus_token_over_delivery_reverts() public {
        // Exact-delivery is `!=`, not `>=`: OVER-delivery (destination credited
        // amount + 1) must also revert atomically, pinning the strict-equality
        // direction the fee-on-transfer test doesn't cover.
        BonusToken token = new BonusToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert(SpendRouter.SpendTransferFailed.selector);
        router.pay(TOPIC, 25e6, keccak256("hostile-bonus"));
        vm.stopPrank();
        // Post-revert state is fully intact: balances unmoved, order unconsumed.
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertFalse(router.orderConsumed(keccak256("hostile-bonus")));
    }

    function test_no_return_token_reverts_atomically() public {
        // USDT-style token: mutates balances, returns no data. The router's
        // IERC20Minimal expects a bool, so abi-decoding the empty return
        // reverts the whole call — generic revert (not SpendTransferFailed),
        // but atomic: nothing moves, order unconsumed.
        NoReturnToken token = new NoReturnToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(router), 25e6);
        vm.expectRevert();
        router.pay(TOPIC, 25e6, keccak256("hostile-nr"));
        vm.stopPrank();
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 0);
        assertFalse(router.orderConsumed(keccak256("hostile-nr")));
    }

    function test_reentrant_same_order_cannot_replay() public {
        ReentrantToken token = new ReentrantToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        bytes32 orderId = keccak256("hostile-3");
        // Reentry attempts the SAME order — blocked by the reentrancy lock
        // (and the already-consumed order behind it); the token swallows the
        // inner revert and the outer spend completes exactly once.
        token.setAttack(
            address(router), abi.encodeCall(EchoSpendRouter.pay, (TOPIC, 25e6, orderId))
        );
        vm.startPrank(user);
        token.approve(address(router), 100e6);
        router.pay(TOPIC, 25e6, orderId);
        vm.stopPrank();
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 25e6, "spent exactly once");
        assertEq(token.balanceOf(user), 75e6);
    }

    function test_reentrant_fresh_order_same_destination_blocked() public {
        ReentrantToken token = new ReentrantToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        // Reentry tries a FRESH order at the SAME destination, riding the
        // user's standing allowance through the front-run-tolerance branch.
        // The reentrancy lock rejects the nested spend; the outer completes
        // exactly once and the nested order is never consumed.
        token.setAttack(
            address(router),
            abi.encodeCall(
                EchoSpendRouter.payWithPermit,
                (
                    TOPIC,
                    10e6,
                    keccak256("hostile-4b"),
                    user,
                    block.timestamp + 1 hours,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );
        vm.startPrank(user);
        token.approve(address(router), 100e6);
        router.pay(TOPIC, 25e6, keccak256("hostile-4a"));
        vm.stopPrank();
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 25e6, "outer only");
        assertEq(token.balanceOf(user), 75e6);
        assertTrue(router.orderConsumed(keccak256("hostile-4a")));
        assertFalse(router.orderConsumed(keccak256("hostile-4b")), "nested order rejected");
    }

    function test_reentrant_fresh_order_different_destination_blocked() public {
        // The case the exact-delivery check alone could NOT catch: a nested
        // spend at a DIFFERENT destination (different topic). Only the
        // reentrancy lock stops it — this is its load-bearing test.
        ReentrantToken token = new ReentrantToken();
        EchoSpendRouter router = new EchoSpendRouter(address(token), anchor, address(0));
        token.mint(user, 100e6);
        bytes32 evilTopic = keccak256("evil-topic");
        token.setAttack(
            address(router),
            abi.encodeCall(
                EchoSpendRouter.payWithPermit,
                (
                    evilTopic,
                    10e6,
                    keccak256("hostile-5b"),
                    user,
                    block.timestamp + 1 hours,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );
        vm.startPrank(user);
        token.approve(address(router), 100e6);
        router.pay(TOPIC, 25e6, keccak256("hostile-5a"));
        vm.stopPrank();
        assertEq(token.balanceOf(router.destinationFor(TOPIC, user)), 25e6, "outer only");
        assertEq(token.balanceOf(router.destinationFor(evilTopic, user)), 0, "nested blocked");
        assertEq(token.balanceOf(user), 75e6);
        assertFalse(router.orderConsumed(keccak256("hostile-5b")));
        // Pin the MECHANISM, not just the outcome: the nested spend was
        // rejected specifically by the reentrancy lock (Reentrancy()), not
        // incidentally by permit/allowance/exact-delivery checks.
        assertEq(
            token.lastInnerRevert(),
            abi.encodeWithSelector(SpendRouter.Reentrancy.selector),
            "nested spend rejected by the reentrancy lock"
        );
    }
}
