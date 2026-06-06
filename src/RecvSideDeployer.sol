// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { CCIPDVNAdapter }  from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { ICCIPDVNAdapter } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol";
import { DVNBroadcaster }  from "lz-dvn-broadcaster/DVNBroadcaster.sol";

contract RecvSideDeployer {
    uint32  internal constant L1_EID            = 30101;               // https://docs.layerzero.network/v2/deployments/deployed-contracts
    uint64  internal constant L1_CHAIN_SELECTOR = 5009297550715157269; // https://docs.chain.link/ccip/directory/mainnet/chain/mainnet

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");

    CCIPDVNAdapter public immutable adapter;
    DVNBroadcaster public immutable ccipBroadcaster;
    DVNBroadcaster public immutable msigBroadcaster;

    constructor(
        address ccipRouter,
        address receiveLib,
        address sourceCcipAdapter,
        address multisig,
        uint256 nCcip,
        uint256 nMsig
    ) {
        address[] memory admins = new address[](1);
        admins[0] = address(this);
        adapter = new CCIPDVNAdapter(admins, ccipRouter);

        ICCIPDVNAdapter.DstConfigParam[] memory dstCfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        dstCfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           L1_EID,
            multiplierBps: 0,
            chainSelector: L1_CHAIN_SELECTOR,
            gas:           0,
            peer:          abi.encode(sourceCcipAdapter)
        });
        adapter.setDstConfig(dstCfg);

        ccipBroadcaster = new DVNBroadcaster(receiveLib, address(adapter), nCcip);
        msigBroadcaster = new DVNBroadcaster(receiveLib, multisig,         nMsig);

        adapter.revokeRole(ADMIN_ROLE,         address(this));
        adapter.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}
