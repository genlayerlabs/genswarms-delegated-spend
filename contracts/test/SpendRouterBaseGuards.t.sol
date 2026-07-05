// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpendRouter} from "../src/SpendRouter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Test-only harness exposing _routeSpend raw, to unit-test the base
///         guards that no well-formed concrete router can reach (zero/self
///         destination). NOT a template for consumers — real routers derive
///         the destination, never accept it.
contract RawRouterHarness is SpendRouter {
    constructor(address token_, address anchor_) SpendRouter(token_, anchor_, address(0)) {}

    function routerType() external pure override returns (bytes32) {
        return keccak256("RAW_HARNESS");
    }

    function route(address user, address destination, uint256 amount, bytes32 orderId) external {
        _routeSpend(user, destination, amount, orderId);
    }
}

/// @notice Unit pins for the SpendRouter base guards and event.
contract SpendRouterBaseGuardsTest is Test {
    MockERC20Permit token;
    RawRouterHarness harness;
    address anchor = address(0xA4C402);
    address user = address(0xA11CE7);
    address dest = address(0xDE57);

    function setUp() public {
        token = new MockERC20Permit();
        harness = new RawRouterHarness(address(token), anchor);
        token.mint(user, 100e6);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
    }

    function test_constructor_rejects_zero_token() public {
        vm.expectRevert(SpendRouter.ZeroAddress.selector);
        new RawRouterHarness(address(0), anchor);
    }

    function test_constructor_rejects_zero_anchor() public {
        vm.expectRevert(SpendRouter.ZeroAddress.selector);
        new RawRouterHarness(address(token), address(0));
    }

    function test_zero_destination_rejected() public {
        vm.expectRevert(SpendRouter.ZeroAddress.selector);
        harness.route(user, address(0), 25e6, keccak256("guard-1"));
    }

    function test_router_as_destination_rejected() public {
        // The router must never hold funds, even via a buggy concrete
        // derivation that returns the router itself.
        vm.expectRevert(SpendRouter.ZeroAddress.selector);
        harness.route(user, address(harness), 25e6, keccak256("guard-2"));
    }

    // Local re-declaration for vm.expectEmit (solc 0.8.20 has no qualified
    // `emit Contract.Event` syntax).
    event SpendRouted(
        address indexed user, address indexed destination, uint256 amount, bytes32 indexed orderId
    );

    function test_spend_routed_event_exact_params() public {
        vm.expectEmit(true, true, true, true, address(harness));
        emit SpendRouted(user, dest, 25e6, keccak256("guard-3"));
        harness.route(user, dest, 25e6, keccak256("guard-3"));
    }
}
