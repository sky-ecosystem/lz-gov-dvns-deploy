// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { CCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { CCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapterFeeLib.sol";
import { LZDVNInit, CCIPDVNCfg } from "./LZDVNInit.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

contract SendSideDeployer {
    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // Worker declares these `internal`, so we recompute them.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");

    address public immutable deployer;
    address public immutable adapter;
    address public immutable feeLib;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "SendSideDeployer/not-deployer");
        _;
    }

    constructor(address ccipRouter) {
        deployer = msg.sender;

        address[] memory admins = new address[](1);
        admins[0] = address(this);

        CCIPDVNAdapter       a = new CCIPDVNAdapter(admins, ccipRouter);
        CCIPDVNAdapterFeeLib f = new CCIPDVNAdapterFeeLib();
        adapter = address(a);
        feeLib  = address(f);

        // Upstream FeeLib is built for hardhat-deploy proxies. Calling
        // initialize() once on a freshly deployed instance seals the `proxied`
        // admin slot and runs __Ownable_init() with msg.sender as owner.
        f.initialize();

        a.setWorkerFeeLib(feeLib);
    }

    function configure(CCIPDVNCfg calldata cfg) external onlyDeployer {
        LZDVNInit.wireCCIPDVN(adapter, feeLib, cfg);
    }

    /// @dev Hands FeeLib ownership and adapter admin to PAUSE_PROXY (read from
    ///      chainlog), then self-revokes. Uses `revokeRole` since Worker
    ///      disables `renounceRole`.
    function handOff(address[] calldata revokeOApps) external onlyDeployer {
        address pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");
        CCIPDVNAdapter a = CCIPDVNAdapter(payable(adapter));

        for (uint256 i = 0; i < revokeOApps.length; ++i) {
            a.revokeRole(ALLOWLIST, revokeOApps[i]);
        }

        CCIPDVNAdapterFeeLib(feeLib).transferOwnership(pauseProxy);

        a.grantRole(DEFAULT_ADMIN_ROLE, pauseProxy);
        a.grantRole(ADMIN_ROLE,         pauseProxy);

        a.revokeRole(ADMIN_ROLE,         address(this));
        a.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}
