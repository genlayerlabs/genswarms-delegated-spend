// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20Permit} from "./MockERC20Permit.sol";

/// @notice transferFrom lies: returns false without moving funds.
contract ReturnFalseToken is MockERC20Permit {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @notice Fee-on-transfer: destination receives amount - 1.
contract FeeOnTransferToken is MockERC20Permit {
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        super.transferFrom(from, to, amount);
        // burn 1 unit out of the destination — simulates a transfer fee
        balanceOf[to] -= 1;
        return true;
    }
}

/// @notice Over-delivery: destination receives amount + 1 (bonus/rebasing-style
///         credit). The exact-delivery check must reject this direction too.
contract BonusToken is MockERC20Permit {
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        super.transferFrom(from, to, amount);
        // mint 1 bonus unit into the destination — simulates over-delivery
        balanceOf[to] += 1;
        return true;
    }
}

/// @notice USDT-style: transferFrom mutates balances but returns NOTHING.
///         Cannot subclass MockERC20Permit (return-type clash), so it is a
///         minimal standalone token for the direct lane.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "NoReturnToken: allowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "NoReturnToken: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Reentrant: on the first transferFrom, calls back into an arbitrary
///         target with an arbitrary payload (swallowing its revert), then
///         proceeds normally.
contract ReentrantToken is MockERC20Permit {
    address public attackTarget;
    bytes public attackPayload;
    bool internal reentered;
    /// @notice Revert data of the swallowed inner call, so tests can pin WHICH
    ///         error rejected the nested spend (empty if the inner call succeeded).
    bytes public lastInnerRevert;

    function setAttack(address target, bytes calldata payload) external {
        attackTarget = target;
        attackPayload = payload;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        if (attackTarget != address(0) && !reentered) {
            reentered = true;
            (bool ok, bytes memory ret) = attackTarget.call(attackPayload);
            if (!ok) lastInnerRevert = ret;
            // swallow — the router invariants must hold regardless
        }
        return super.transferFrom(from, to, amount);
    }
}
