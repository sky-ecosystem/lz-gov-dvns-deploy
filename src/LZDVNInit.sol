// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { ICCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol";
import { ICCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapterFeeLib.sol";
import { ReceiveLibParam }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/DVNAdapterBase.sol";

interface CCIPDVNAdapterLike {
    function setDstConfig    (ICCIPDVNAdapter.DstConfigParam[] calldata) external;
    function setReceiveLibs  (ReceiveLibParam[] calldata) external;
    function grantRole       (bytes32 role, address account) external;
}

interface CCIPDVNAdapterFeeLibLike {
    function setDstConfig(ICCIPDVNAdapterFeeLib.DstConfigParam[] calldata) external;
}

struct CCIPDVNRemote {
    uint32  remoteEid;
    address sendUln302;
    uint64  remoteChainSelector;
    address remoteCcipAdapter;
    address remoteCcipBroadcaster;
    uint16  multiplierBps;
    uint256 gas;
    uint128 floorMarginUSD;
}

/// @notice Spell-callable wiring helper for the CCIP DVN adapter and FeeLib.
///         Caller must hold ADMIN_ROLE + DEFAULT_ADMIN_ROLE on the adapter and
///         own the FeeLib (deployer at bring-up via SendSideDeployer.configure;
///         PauseProxy via spell after handoff).
library LZDVNInit {

    bytes32 internal constant ALLOWLIST = keccak256("ALLOWLIST");

    function wireCCIPDVN(
        address               adapter,
        address               feeLib,
        CCIPDVNRemote memory  remote,
        address[]     memory  allowedOApps
    ) internal {
        CCIPDVNAdapterLike a = CCIPDVNAdapterLike(adapter);

        {
            ICCIPDVNAdapter.DstConfigParam[] memory params = new ICCIPDVNAdapter.DstConfigParam[](1);
            params[0] = ICCIPDVNAdapter.DstConfigParam({
                eid:           remote.remoteEid,
                multiplierBps: remote.multiplierBps,
                chainSelector: remote.remoteChainSelector,
                gas:           remote.gas,
                peer:          abi.encode(remote.remoteCcipAdapter)
            });
            a.setDstConfig(params);
        }

        // receiveLibs redirect: CCIP-delivered packets land at the remote
        // broadcaster (decoded from this bytes32) instead of the real
        // ReceiveUln302, which fans verify out across the N replicas.
        {
            ReceiveLibParam[] memory params = new ReceiveLibParam[](1);
            params[0] = ReceiveLibParam({
                sendLib:    remote.sendUln302,
                dstEid:     remote.remoteEid,
                receiveLib: bytes32(uint256(uint160(remote.remoteCcipBroadcaster)))
            });
            a.setReceiveLibs(params);
        }

        {
            ICCIPDVNAdapterFeeLib.DstConfigParam[] memory params = new ICCIPDVNAdapterFeeLib.DstConfigParam[](1);
            params[0] = ICCIPDVNAdapterFeeLib.DstConfigParam({
                dstEid:         remote.remoteEid,
                floorMarginUSD: remote.floorMarginUSD
            });
            CCIPDVNAdapterFeeLibLike(feeLib).setDstConfig(params);
        }

        // First grantRole(ALLOWLIST, _) flips allowlistSize > 0 and makes the
        // ACL strict (deny-by-default).
        for (uint256 i = 0; i < allowedOApps.length; ++i) {
            a.grantRole(ALLOWLIST, allowedOApps[i]);
        }
    }
}
