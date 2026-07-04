// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpendRouter} from "./interfaces/ISpendRouter.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20PermitMinimal {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @notice Abstract non-custodial spend router — the audited core of
///         genswarms-delegated-spend.
///
/// A concrete router adds exactly ONE typed money-moving action (plus its
/// `...WithPermit` variant) and derives the funds destination through a
/// beneficiary-binding derivation whose beneficiary input IS the structurally
/// derived user (permit signer / delegation-lane msg.sender). The base owns:
///
/// - the only token-moving path: a single `transferFrom(user → destination)`
///   with an exact-delivery check — the router never holds funds, even
///   transiently;
/// - orderId idempotency (a consumed orderId reverts; keeper retries can
///   never double-spend), scoped per router instance;
/// - permit application with front-run tolerance (a signature consumed by a
///   front-runner is fine if the allowance it set is still sufficient).
///
/// Deliberately absent, forever: owner, pause, upgrade, rescue, generic
/// execute. User recourse against a misbehaving keeper is wallet-side
/// revocation; app recourse is deploying a new router and updating config.
/// These absences are pinned by the ABI test in SpendRouterTestBase.
abstract contract SpendRouter is ISpendRouter {
    address public immutable token;
    address public immutable anchor;
    /// @dev Introspection only — the router never calls the DelegationManager
    ///      (7710 redemptions execute inside the user's account and arrive
    ///      here as plain calls). MAY be zero on a permit-only M1 deployment.
    address public immutable delegationManager;

    mapping(bytes32 => bool) private _consumedOrders;

    error ZeroAddress();
    error ZeroAmount();
    error ZeroOrderId();
    error OrderAlreadyConsumed(bytes32 orderId);
    error PermitRejected();
    error SpendTransferFailed();

    event SpendRouted(
        address indexed user,
        address indexed destination,
        uint256 amount,
        bytes32 indexed orderId
    );

    constructor(address token_, address anchor_, address delegationManager_) {
        if (token_ == address(0) || anchor_ == address(0)) revert ZeroAddress();
        token = token_;
        anchor = anchor_;
        delegationManager = delegationManager_;
    }

    function version() public pure returns (string memory) {
        return "0.1.0";
    }

    function routerType() external pure virtual returns (bytes32);

    function orderConsumed(bytes32 orderId) external view returns (bool) {
        return _consumedOrders[orderId];
    }

    /// @dev Permit lane: apply the user's EIP-2612 signature (user → this
    ///      router, exact value). Front-run tolerance: if `permit` reverts but
    ///      the allowance is already sufficient (signature consumed by a
    ///      front-runner), proceed — the standard check-allowance pattern.
    function _applyPermit(
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        try IERC20PermitMinimal(token).permit(owner, address(this), value, deadline, v, r, s) {
            // allowance set by permit
        } catch {
            if (IERC20Minimal(token).allowance(owner, address(this)) < value) {
                revert PermitRejected();
            }
        }
    }

    /// @dev The ONLY token-moving path. Checks-effects-interactions: the order
    ///      is consumed before the external transfer, so a reentrant token can
    ///      never replay it. The exact-delivery check rejects fee-on-transfer
    ///      behavior (destination must receive exactly `amount`).
    function _routeSpend(
        address user,
        address destination,
        uint256 amount,
        bytes32 orderId
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (destination == address(0) || destination == address(this)) revert ZeroAddress();
        if (orderId == bytes32(0)) revert ZeroOrderId();
        if (_consumedOrders[orderId]) revert OrderAlreadyConsumed(orderId);
        _consumedOrders[orderId] = true;

        uint256 destBefore = IERC20Minimal(token).balanceOf(destination);
        bool ok = IERC20Minimal(token).transferFrom(user, destination, amount);
        if (!ok) revert SpendTransferFailed();
        if (IERC20Minimal(token).balanceOf(destination) != destBefore + amount) {
            revert SpendTransferFailed();
        }

        emit SpendRouted(user, destination, amount, orderId);
    }
}
