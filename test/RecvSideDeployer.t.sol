// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { CCIPDVNAdapter } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { DVNBroadcaster } from "lz-dvn-broadcaster/DVNBroadcaster.sol";

import { RecvSideDeployer } from "../src/RecvSideDeployer.sol";

// Mainnet-fork unit tests for the single-tx remote-side deployer. All wiring
// (adapter dst-config back to L1, the two broadcaster wings, and admin revocation)
// happens inside the constructor, so the tests assert on post-construction state.
contract RecvSideTest is Test {
    address constant CCIP_ROUTER       = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint32  constant L1_EID            = 30101;
    uint64  constant L1_CHAIN_SELECTOR = 5009297550715157269;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");

    uint256 constant N_CCIP = 3;
    uint256 constant N_MSIG = 2;

    address endpoint         = makeAddr("endpoint");
    address sourceCcipAdapter = makeAddr("sourceCcipAdapter");
    address multisig         = makeAddr("multisig");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
    }

    function _deploy() internal returns (RecvSideDeployer) {
        return new RecvSideDeployer({
            ccipRouter:        CCIP_ROUTER,
            endpoint:          endpoint,
            sourceCcipAdapter: sourceCcipAdapter,
            multisig:          multisig,
            nCcip:             N_CCIP,
            nMsig:             N_MSIG
        });
    }

    function test_constructor() public {
        RecvSideDeployer recv = _deploy();
        CCIPDVNAdapter   adapter = recv.adapter();

        // Adapter points at the supplied CCIP router.
        assertEq(address(adapter.router()), CCIP_ROUTER);

        (uint32 eid, bytes memory peer) = adapter.srcConfig(L1_CHAIN_SELECTOR);
        assertEq(eid,  L1_EID % 30000);
        assertEq(peer, abi.encode(sourceCcipAdapter));

        // Two broadcaster wings with the requested replica counts.
        DVNBroadcaster ccip = recv.ccipBroadcaster();
        DVNBroadcaster msig = recv.msigBroadcaster();
        assertEq(ccip.getReplicas().length, N_CCIP);
        assertEq(msig.getReplicas().length, N_MSIG);

        // Wings share the endpoint; CCIP wing verifies via the adapter, msig wing via the multisig.
        assertEq(ccip.endpoint(), endpoint);
        assertEq(msig.endpoint(), endpoint);
        assertEq(ccip.verifier(), address(adapter));
        assertEq(msig.verifier(), multisig);

        // No admin is ever granted and the deployer is revoked,
        // so the adapter is provably unable to send.
        assertFalse(adapter.hasRole(DEFAULT_ADMIN_ROLE, address(recv)));
        assertFalse(adapter.hasRole(ADMIN_ROLE,         address(recv)));
    }
}
