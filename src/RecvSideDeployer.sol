// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { CCIPDVNAdapter }  from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { ICCIPDVNAdapter } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol";
import { DVNBroadcaster }  from "lz-gov-dvns/DVNBroadcaster.sol";

contract RecvSideDeployer {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");

    address   public immutable adapter;
    address   public immutable ccipBroadcaster;
    address   public immutable msigBroadcaster;
    address[] public           ccipReplicas;
    address[] public           msigReplicas;

    /// @dev `finalAdmin == address(0)` leaves no admin on the adapter
    ///      (provably can't send — no one can grant MESSAGE_LIB_ROLE).
    /// @dev Self-revoke uses `revokeRole` (not `renounceRole`, which Worker disables).
    constructor(
        uint32  sourceEid,
        address ccipRouter,
        uint64  sourceChainSelector,
        address sourceCcipAdapter,
        address receiveUln302,
        address multisig,
        uint256 nCcip,
        uint256 nMsig,
        address finalAdmin
    ) {
        address[] memory admins = new address[](1);
        admins[0] = address(this);

        CCIPDVNAdapter a = new CCIPDVNAdapter(admins, ccipRouter);
        adapter = address(a);

        ICCIPDVNAdapter.DstConfigParam[] memory dstCfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        dstCfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           sourceEid,
            multiplierBps: 0,
            chainSelector: sourceChainSelector,
            gas:           0,
            peer:          abi.encode(sourceCcipAdapter)
        });
        a.setDstConfig(dstCfg);

        // Broadcaster ctors take no roles; safe to deploy before admin handoff.
        DVNBroadcaster ccipB = new DVNBroadcaster(receiveUln302, adapter,  nCcip);
        DVNBroadcaster msigB = new DVNBroadcaster(receiveUln302, multisig, nMsig);
        ccipBroadcaster = address(ccipB);
        msigBroadcaster = address(msigB);
        ccipReplicas    = ccipB.getReplicas();
        msigReplicas    = msigB.getReplicas();

        if (finalAdmin != address(0)) {
            a.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
            a.grantRole(ADMIN_ROLE,         finalAdmin);
        }
        a.revokeRole(ADMIN_ROLE,         address(this));
        a.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}
