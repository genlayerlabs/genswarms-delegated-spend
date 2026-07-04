// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Introspection surface every SpendRouter instance exposes. Config
///         verifiers — keeper boot checks, Mini App sanity checks, deployment
///         attestation — read these views to confirm they point at the router
///         they think they do.
interface ISpendRouter {
    function token() external view returns (address);
    function anchor() external view returns (address);
    function delegationManager() external view returns (address);
    function routerType() external pure returns (bytes32);
    function version() external pure returns (string memory);
    function orderConsumed(bytes32 orderId) external view returns (bool);
}
