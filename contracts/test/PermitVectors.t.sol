// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Golden-vector redemption (spec §8, 3-language cross-check): the
///         Mini App's ACTUAL encoding code generated vectors/permit/*.json
///         (signed by cast's independent EIP-712 implementation); this suite
///         deploys the USDC-shaped mock at the PINNED vector address and
///         redeems each signature for real. If the webapp's typed-data
///         construction drifts from the token's on-chain digest by one byte,
///         permit() reverts here.
contract PermitVectorsTest is Test {
    address constant TOKEN = 0x000000000000000000000000000000000000aaaa;

    string[3] vectors = ["permit-eoa-1", "permit-eoa-min", "permit-eoa-large"];

    function _load(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat("../vectors/permit/", name, ".json"));
    }

    function test_vectors_redeem_on_chain_and_replay_reverts() public {
        assertEq(block.chainid, 31337, "vectors pin the default test chain id");

        deployCodeTo("MockERC20Permit.sol:MockERC20Permit", "", TOKEN);

        for (uint256 i = 0; i < vectors.length; i++) {
            // fresh STATE per vector (each vector pins nonce 0): deployCodeTo
            // re-etches code but storage persists, so snapshot/revert instead
            uint256 snap = vm.snapshotState();
            string memory json = _load(vectors[i]);

            address owner = vm.parseJsonAddress(json, ".permit.owner");
            address spender = vm.parseJsonAddress(json, ".permit.spender");
            uint256 value = vm.parseJsonUint(json, ".permit.value");
            uint256 deadline = vm.parseJsonUint(json, ".permit.deadline");
            uint8 v = uint8(vm.parseJsonUint(json, ".signature.v"));
            bytes32 r = vm.parseJsonBytes32(json, ".signature.r");
            bytes32 s = vm.parseJsonBytes32(json, ".signature.s");

            MockERC20Permit token = MockERC20Permit(TOKEN);
            // pin the domain separator the vectors were built against
            assertEq(
                token.DOMAIN_SEPARATOR(),
                bytes32(0x312790fe3331b28e5f85e406d4a94c65b588a45116faf64750da91e7d1d0ce3b),
                "deployed token domain separator matches vector domain"
            );
            token.permit(owner, spender, value, deadline, v, r, s);
            assertEq(token.allowance(owner, spender), value, "vector redeemed");
            assertEq(token.nonces(owner), 1, "nonce consumed");

            vm.expectRevert("MockERC20Permit: bad permit sig");
            token.permit(owner, spender, value, deadline, v, r, s);

            vm.revertToState(snap);
        }
    }

    function test_tampered_value_rejected() public {
        deployCodeTo("MockERC20Permit.sol:MockERC20Permit", "", TOKEN);
        string memory json = _load("permit-eoa-1");

        address owner = vm.parseJsonAddress(json, ".permit.owner");
        address spender = vm.parseJsonAddress(json, ".permit.spender");
        uint256 value = vm.parseJsonUint(json, ".permit.value");
        uint256 deadline = vm.parseJsonUint(json, ".permit.deadline");
        uint8 v = uint8(vm.parseJsonUint(json, ".signature.v"));
        bytes32 r = vm.parseJsonBytes32(json, ".signature.r");
        bytes32 s = vm.parseJsonBytes32(json, ".signature.s");

        vm.expectRevert("MockERC20Permit: bad permit sig");
        MockERC20Permit(TOKEN).permit(owner, spender, value + 1, deadline, v, r, s);
    }
}
