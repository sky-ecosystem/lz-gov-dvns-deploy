// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { OApp, MessagingFee, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import { DVNBroadcaster }   from "lz-gov-dvns/DVNBroadcaster.sol";

import { SendSideDeployer } from "../../src/SendSideDeployer.sol";
import { RecvSideDeployer } from "../../src/RecvSideDeployer.sol";
import { CCIPDVNCfg }       from "../../src/LZDVNInit.sol";

// Minimal OApp: sends an empty payload, increments `count` on receipt.
contract Counter is OApp {
    uint256 public count;
    constructor(address _endpoint, address _delegate) OApp(_endpoint, _delegate) {}
    function send(uint32 _dstEid, bytes calldata _options) external payable returns (MessagingFee memory fee) {
        fee = _quote(_dstEid, "", _options, false);
        require(msg.value >= fee.nativeFee, "Counter/fee");
        _lzSend(_dstEid, "", _options, fee, payable(msg.sender));
    }
    function quote(uint32 _dstEid, bytes calldata _options) external view returns (MessagingFee memory) {
        return _quote(_dstEid, "", _options, false);
    }
    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal override {
        ++count;
    }
}

struct SetConfigParam   { uint32 eid; uint32 configType; bytes config; }
struct UlnConfig        { uint64 confirmations; uint8 requiredDVNCount; uint8 optionalDVNCount; uint8 optionalDVNThreshold; address[] requiredDVNs; address[] optionalDVNs; }
struct ExecutorConfig   { uint32 maxMessageSize; address executor; }

interface EndpointLike {
    function setSendLibrary(address oapp, uint32 eid, address newLib) external;
    function setReceiveLibrary(address oapp, uint32 eid, address newLib, uint256 gracePeriod) external;
    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external;
}

// Deploys a fresh, disposable Counter OApp pair on mainnet + Base, configures DVNs
// (4 CCIP + 4 msig replicas on recv side; both wings in recv UlnConfig at threshold=4 so
// CCIP wing alone delivers), sends one packet, hands off send-side admin to MCD_PAUSE_PROXY.
// Self-contained, rerunnable.
contract StagingE2E is Script {
    address constant LZ_ENDPOINT          = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32  constant L1_EID               = 30101;
    address constant L1_SEND_ULN_302      = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant L1_LZ_EXECUTOR       = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    uint32  constant BASE_EID             = 30184;
    uint64  constant BASE_CHAIN_SELECTOR  = 15971525489660198786;
    address constant BASE_CCIP_ROUTER     = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant BASE_RECEIVE_ULN_302 = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;

    uint128 constant LZ_RECEIVE_GAS = 100_000;
    uint256 constant ADAPTER_FUND   = 0.001 ether;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");

        // ---- L1: deploy SendSideDeployer + Counter ----
        uint256 l1Fork = vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        vm.startBroadcast(deployer);
        Counter l1Counter = new Counter(LZ_ENDPOINT, deployer);
        address[] memory allowed = new address[](1);
        allowed[0] = address(l1Counter);
        SendSideDeployer sendD = new SendSideDeployer(L1_SEND_ULN_302, allowed);
        address l1Adapter = address(sendD.adapter());
        vm.stopBroadcast();

        // ---- Base: deploy RecvSideDeployer + Counter, wire L2 Counter ----
        Counter        l2Counter;
        RecvSideDeployer recvD;
        address recvAdapter;
        address ccipBroadcaster;
        {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
            vm.startBroadcast(deployer);
            recvD = new RecvSideDeployer({
                ccipRouter:        BASE_CCIP_ROUTER,
                receiveUln302:     BASE_RECEIVE_ULN_302,
                sourceCcipAdapter: l1Adapter,
                multisig:          deployer,    // staging: deployer plays the msig
                nCcip:             4,
                nMsig:             4,
                finalAdmin:        address(0)   // staging: recv adapter fully locked
            });
            l2Counter       = new Counter(LZ_ENDPOINT, deployer);
            recvAdapter     = address(recvD.adapter());
            ccipBroadcaster = address(recvD.ccipBroadcaster());

            // Both wings in the UlnConfig; threshold = ccip replica count (CCIP wing alone satisfies; msig wing not exercised here).
            address[] memory ccipReplicas = recvD.ccipBroadcaster().getReplicas();
            address[] memory msigReplicas = recvD.msigBroadcaster().getReplicas();

            l2Counter.setPeer(L1_EID, bytes32(uint256(uint160(address(l1Counter)))));
            EndpointLike(LZ_ENDPOINT).setReceiveLibrary(address(l2Counter), L1_EID, BASE_RECEIVE_ULN_302, 0);
            _setRecvUln(address(l2Counter), _sortedConcat(ccipReplicas, msigReplicas), uint8(ccipReplicas.length));
            vm.stopBroadcast();
        }

        // ---- L1: configure send side + wire L1 Counter + send + handoff ----
        vm.selectFork(l1Fork);
        vm.startBroadcast(deployer);

        sendD.configure(CCIPDVNCfg({
            remoteEid:             BASE_EID,
            remoteChainSelector:   BASE_CHAIN_SELECTOR,
            remoteCcipAdapter:     recvAdapter,
            remoteCcipBroadcaster: ccipBroadcaster,
            sendUln302:            L1_SEND_ULN_302,
            multiplierBps:         12000,
            gas:                   200_000,
            allowedOApps:          allowed
        }));

        l1Counter.setPeer(BASE_EID, bytes32(uint256(uint160(address(l2Counter)))));
        EndpointLike(LZ_ENDPOINT).setSendLibrary(address(l1Counter), BASE_EID, L1_SEND_ULN_302);
        _setSendUln(address(l1Counter), l1Adapter);

        // Prefund adapter — CCIP fee is paid before the SendLib deposit lands on first send.
        (bool ok, ) = l1Adapter.call{ value: ADAPTER_FUND }("");
        require(ok, "fund-failed");

        bytes memory options = abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), LZ_RECEIVE_GAS);
        MessagingFee memory fee = l1Counter.quote(BASE_EID, options);
        l1Counter.send{ value: fee.nativeFee }(BASE_EID, options);

        address[] memory toRevoke = new address[](1);
        toRevoke[0] = address(l1Counter);
        sendD.handOff(toRevoke);

        vm.stopBroadcast();

        console.log("L1 SendSideDeployer:",   address(sendD));
        console.log("L1 adapter:",            l1Adapter);
        console.log("L1 feeLib:",             address(sendD.feeLib()));
        console.log("L1 Counter:",            address(l1Counter));
        console.log("Base RecvSideDeployer:", address(recvD));
        console.log("Base adapter:",          recvAdapter);
        console.log("Base ccipBroadcaster:",  ccipBroadcaster);
        console.log("Base Counter:",          address(l2Counter));
    }

    // 1/1: single optional DVN = the send-side adapter.
    function _setSendUln(address oapp, address adapter) private {
        address[] memory dvns = new address[](1);
        dvns[0] = adapter;
        UlnConfig memory uln = UlnConfig({
            confirmations:        1,
            requiredDVNCount:     255,                    // NIL
            optionalDVNCount:     1,
            optionalDVNThreshold: 1,
            requiredDVNs:         new address[](0),
            optionalDVNs:         dvns
        });
        ExecutorConfig memory exec = ExecutorConfig({ maxMessageSize: 10000, executor: L1_LZ_EXECUTOR });
        SetConfigParam[] memory p = new SetConfigParam[](2);
        p[0] = SetConfigParam(BASE_EID, 1, abi.encode(exec));
        p[1] = SetConfigParam(BASE_EID, 2, abi.encode(uln));
        EndpointLike(LZ_ENDPOINT).setConfig(oapp, L1_SEND_ULN_302, p);
    }

    // Both wings (4 CCIP + 4 msig replicas) listed as optional; threshold lets one wing satisfy alone.
    function _setRecvUln(address oapp, address[] memory replicas, uint8 threshold) private {
        UlnConfig memory uln = UlnConfig({
            confirmations:        1,
            requiredDVNCount:     255,
            optionalDVNCount:     uint8(replicas.length),
            optionalDVNThreshold: threshold,
            requiredDVNs:         new address[](0),
            optionalDVNs:         replicas
        });
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(L1_EID, 2, abi.encode(uln));
        EndpointLike(LZ_ENDPOINT).setConfig(oapp, BASE_RECEIVE_ULN_302, p);
    }

    function _sortedConcat(address[] memory a, address[] memory b) private pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; ++i) out[i]            = a[i];
        for (uint256 i = 0; i < b.length; ++i) out[a.length + i] = b[i];
        for (uint256 i = 1; i < out.length; ++i) {
            for (uint256 j = i; j > 0 && out[j - 1] > out[j]; --j) {
                (out[j - 1], out[j]) = (out[j], out[j - 1]);
            }
        }
    }

}
