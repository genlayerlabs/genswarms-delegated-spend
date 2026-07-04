// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SpendRouter} from "../SpendRouter.sol";

/// @notice Toy consumer proving the adoption contract and exercised by the
///         package's own CI. Its "funds destination" is a pure
///         beneficiary-bound hash — a stand-in for a real app's claim-bound
///         CREATE2 view (e.g. MicroMarkets' EscrowVault.depositAddress).
///         Lives under src/examples/ so Foundry compiles it, but consumers
///         importing the lib simply never import it.
contract EchoSpendRouter is SpendRouter {
    event EchoPaid(
        bytes32 indexed topic,
        address indexed payer,
        address destination,
        uint256 amount,
        bytes32 orderId
    );

    constructor(address token_, address anchor_, address delegationManager_)
        SpendRouter(token_, anchor_, delegationManager_)
    {}

    function routerType() external pure override returns (bytes32) {
        return keccak256("ECHO_SPEND_ROUTER");
    }

    /// @notice Beneficiary-binding derivation: the destination commits to the
    ///         beneficiary. A corrupt `topic` still lands funds at an address
    ///         bound to the user — never redirectable to a third party.
    function destinationFor(bytes32 topic, address beneficiary) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encode(address(this), anchor, topic, beneficiary))))
        );
    }

    /// @notice Delegation-lane shape (M2): the user's account executes
    ///         [token.approve(router, amount), router.pay(...)] — the user is
    ///         msg.sender.
    function pay(bytes32 topic, uint256 amount, bytes32 orderId) external {
        _pay(msg.sender, topic, amount, orderId);
    }

    /// @notice Permit lane (M1): keeper submits, user = permit signer.
    function payWithPermit(
        bytes32 topic,
        uint256 amount,
        bytes32 orderId,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _applyPermit(owner, amount, deadline, v, r, s);
        _pay(owner, topic, amount, orderId);
    }

    function _pay(address user, bytes32 topic, uint256 amount, bytes32 orderId) internal {
        address destination = destinationFor(topic, user);
        _routeSpend(user, destination, amount, orderId);
        emit EchoPaid(topic, user, destination, amount, orderId);
    }
}
