// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "dss-test/DssTest.sol";

import { ILayerZeroEndpointV2, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam, IMessageLibManager } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { Errors }                       from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";

import { DelegateWrapper } from "src/DelegateWrapper.sol";

interface IEndpointDelegates {
    function delegates(address oapp) external view returns (address);
}

// Minimal OApp: only needs allowInitializePath() so the real endpoint will accept
// the first verification on a fresh path.
contract MockOApp {
    function allowInitializePath(Origin calldata) external pure returns (bool) { return true; }
    function nextNonce(uint32, bytes32) external pure returns (uint64) { return 0; }
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable {}
}

contract DelegateWrapperTest is DssTest {
    // Canonical LayerZero v2 EndpointV2 on Ethereum mainnet.
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    // Arbitrum One eid — has a default receive library configured on the mainnet endpoint.
    uint32  constant SRC_EID  = 30110;
    bytes32 constant SENDER   = bytes32(uint256(0xA11CE));

    bytes32 constant NIL = bytes32(type(uint256).max);

    event Kiss(address indexed usr);
    event Diss(address indexed usr);

    ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT);
    DelegateWrapper      wrapper;
    MockOApp             oapp;
    address              receiveLib;

    address ward; // the test contract is the ward (deployer)
    address bud   = makeAddr("bud");
    address rando = makeAddr("rando");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        oapp    = new MockOApp();
        wrapper = new DelegateWrapper(ENDPOINT); // this == ward
        ward    = address(this);

        // Seed one guardian.
        wrapper.kiss(bud);

        // Install the wrapper as the OApp's LZ delegate.
        vm.prank(address(oapp)); endpoint.setDelegate(address(wrapper));

        // The OApp uses the endpoint's default receive library; cache it for verification.
        (receiveLib,) = endpoint.getReceiveLibrary(address(oapp), SRC_EID);
    }

    // --- helpers (caller-parameterized to share the body across bud/ward) ---

    function _checkSkip(address caller) internal {
        assertEq(endpoint.lazyInboundNonce(address(oapp), SRC_EID, SENDER), 0);

        vm.prank(caller); wrapper.skip(address(oapp), SRC_EID, SENDER, 1);

        assertEq(endpoint.lazyInboundNonce(address(oapp), SRC_EID, SENDER), 1);
    }

    function _checkNilify(address caller) internal {
        bytes32 ph = keccak256("payload");
        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), bytes32(0));

        vm.prank(receiveLib); endpoint.verify(Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 1 }), address(oapp), ph);
        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), ph);

        vm.prank(caller); wrapper.nilify(address(oapp), SRC_EID, SENDER, 1, ph);

        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), NIL);
    }

    function _checkClear(address caller) internal {
        bytes32 guid      = keccak256("guid");
        bytes memory msg_ = "governance-payload";
        bytes32 ph        = keccak256(abi.encodePacked(guid, msg_));

        vm.prank(receiveLib); endpoint.verify(Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 1 }), address(oapp), ph);
        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), ph);
        assertEq(endpoint.lazyInboundNonce(address(oapp), SRC_EID, SENDER), 0);

        vm.prank(caller); wrapper.clear(address(oapp), Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 1 }), guid, msg_);

        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), bytes32(0));
        assertEq(endpoint.lazyInboundNonce(address(oapp), SRC_EID, SENDER), 1);
    }

    function _checkBurn(address caller) internal {
        // burn needs a verified hash at a nonce <= lazyInboundNonce. Verify 1 and 2, then
        // clear #2 to push the checkpoint to 2, leaving #1 verified but below it.
        bytes32 ph1     = keccak256("p1");
        bytes32 guid    = keccak256("guid2");
        bytes memory m2 = "m2";
        bytes32 ph2     = keccak256(abi.encodePacked(guid, m2));

        vm.prank(receiveLib); endpoint.verify(Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 1 }), address(oapp), ph1);
        vm.prank(receiveLib); endpoint.verify(Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 2 }), address(oapp), ph2);

        vm.prank(caller); wrapper.clear(address(oapp), Origin({ srcEid: SRC_EID, sender: SENDER, nonce: 2 }), guid, m2);
        assertEq(endpoint.lazyInboundNonce(address(oapp), SRC_EID, SENDER), 2);
        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), ph1);

        vm.prank(caller); wrapper.burn(address(oapp), SRC_EID, SENDER, 1, ph1);

        assertEq(endpoint.inboundPayloadHash(address(oapp), SRC_EID, SENDER, 1), bytes32(0));
    }

    // --- construction / auth ---

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        DelegateWrapper w = new DelegateWrapper(ENDPOINT);

        assertEq(w.wards(address(this)), 1);
        assertEq(w.buds(address(this)),  0);
        assertEq(address(w.endpoint()),  ENDPOINT);
    }

    function testAuth() public {
        checkAuth(address(wrapper), "DelegateWrapper");
    }

    function testKissDiss() public {
        assertEq(wrapper.buds(rando), 0);

        vm.expectEmit(true, true, true, true); emit Kiss(rando);
        wrapper.kiss(rando);
        assertEq(wrapper.buds(rando), 1);

        vm.expectEmit(true, true, true, true); emit Diss(rando);
        wrapper.diss(rando);
        assertEq(wrapper.buds(rando), 0);
    }

    // Every gated entrypoint reverts for a caller that is neither ward nor bud. checkModifier
    // calls each as the test contract, so drop its ward first. kiss/diss are ward-only and
    // setConfig routes through the ward-only fallback (both "not-authorized"); skip/nilify/
    // burn/clear are bud-or-ward ("not-bud-or-ward").
    function testGatedMethods() public {
        wrapper.deny(address(this));
        checkModifier(address(wrapper), "DelegateWrapper/not-authorized", [
            DelegateWrapper.kiss.selector,
            DelegateWrapper.diss.selector,
            IMessageLibManager.setConfig.selector
        ]);
        checkModifier(address(wrapper), "DelegateWrapper/not-bud-or-ward", [
            DelegateWrapper.skip.selector,
            DelegateWrapper.nilify.selector,
            DelegateWrapper.burn.selector,
            DelegateWrapper.clear.selector
        ]);
    }

    // A bud holds the suppression powers but must be rejected from every ward-only
    // entrypoint — the boundary that keeps a guardian strictly weaker than a ward.
    function testBudCannotWard() public {
        vm.startPrank(bud);
        vm.expectRevert("DelegateWrapper/not-authorized"); wrapper.rely(rando);
        vm.expectRevert("DelegateWrapper/not-authorized"); wrapper.deny(rando);
        vm.expectRevert("DelegateWrapper/not-authorized"); wrapper.kiss(rando);
        vm.expectRevert("DelegateWrapper/not-authorized"); wrapper.diss(rando);
        vm.expectRevert("DelegateWrapper/not-authorized"); ILayerZeroEndpointV2(address(wrapper)).setConfig(address(oapp), rando, new SetConfigParam[](0));
        vm.stopPrank();
    }

    // --- suppression functions vs the real endpoint (bud and ward each get a test) ---

    function testSkipAsBud() public {
        _checkSkip(bud);
    }

    function testSkipAsWard() public {
        _checkSkip(ward);
    }

    function testNilifyAsBud() public {
        _checkNilify(bud);
    }

    function testNilifyAsWard() public {
        _checkNilify(ward);
    }

    function testClearAsBud() public {
        _checkClear(bud);
    }

    function testClearAsWard() public {
        _checkClear(ward);
    }

    function testBurnAsBud() public {
        _checkBurn(bud);
    }

    function testBurnAsWard() public {
        _checkBurn(ward);
    }

    // --- fallback (ward-only generic forwarding) ---

    function testFallbackForwards() public {
        // setDelegate isn't a wrapper function, so it hits the fallback and is forwarded to the endpoint
        assertEq(IEndpointDelegates(ENDPOINT).delegates(address(wrapper)), address(0));
        ILayerZeroEndpointV2(address(wrapper)).setDelegate(rando);
        assertEq(IEndpointDelegates(ENDPOINT).delegates(address(wrapper)), rando);
    }

    function testFallbackReturnsData() public {
        // a forwarded call that returns data must bubble that data back to the caller.
        // delegates() isn't a wrapper function, so it routes through the fallback.
        address got = IEndpointDelegates(address(wrapper)).delegates(address(oapp));
        assertEq(got, address(wrapper));
    }

    function testFallbackUnauthorized() public {
        // a bud cannot reach the forwarding path — confirms config functions are out of its reach.
        vm.prank(bud);
        vm.expectRevert("DelegateWrapper/not-authorized");
        ILayerZeroEndpointV2(address(wrapper)).setDelegate(rando);
    }

    function testFallbackBubblesEndpointRevert() public {
        // a forwarded endpoint call that reverts must surface the endpoint's real error.
        SetConfigParam[] memory params = new SetConfigParam[](0);
        vm.expectRevert(Errors.LZ_OnlyRegisteredLib.selector);
        ILayerZeroEndpointV2(address(wrapper)).setConfig(address(oapp), rando, params);
    }
}
