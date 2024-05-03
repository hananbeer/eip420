// SPDX-License-Identifier: Beerware
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {ERC420, TransactionData, OwnerBalance, ExecutionRecord} from "../src/ERC420.sol";

contract CounterTest is Test {
    function setUp() public {}

    function callback(bytes calldata data) external payable {
        console2.log("callback from %x with %s bytes", msg.sender, data.length);
    }

    function callbackInt(uint256 num) external payable {
        console2.log("callbackInt from %x with param: %d", msg.sender, num);
    }

    function _sign(
        string memory name,
        TransactionData memory txn
    ) internal returns (bytes32, bytes32) {
        (address addr, uint256 pk) = makeAddrAndKey(name);
        bytes32 hash = keccak256(abi.encode(txn));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);

        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            // NOTE: the above condition does not seem to ever be true for vm.sign (hence this block is untested)
            // perhaps the library ensuring this?
            console2.log("large s used");
            s = bytes32(
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0 -
                    uint256(s)
            );
            v ^= 1;
        }

        address signer = ecrecover(hash, v, r, s);
        require(signer == addr, "signing issue?");

        return (r, bytes32(uint256(s) | ((uint256(v ^ 1) & 1) << 255)));
    }

    function test_singleOwner() public {
        uint256 quorum = 100;

        string memory name = "alice";
        OwnerBalance[] memory ownerBalances = new OwnerBalance[](1);
        ownerBalances[0] = OwnerBalance(makeAddr(name), uint96(quorum));

        ERC420 erc420 = new ERC420(quorum, ownerBalances);

        TransactionData memory txn = TransactionData({
            callType: 0,
            expiry: uint64(block.timestamp + 1),
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("callback(bytes)", hex"abcd")
        });

        (bytes32 r, bytes32 vs) = _sign(name, txn);

        bytes32[] memory sigs = new bytes32[](2);
        sigs[0] = r;
        sigs[1] = vs;
        erc420.execute(txn, sigs);
    }

    function test_multipleOwners() public {
        uint256 quorum = 10;

        string[4] memory signerNames = [
            "main",
            "secondary",
            "trustee1",
            "trustee2"
        ];

        OwnerBalance[] memory ownerBalances = new OwnerBalance[](4);
        for (uint256 i = 0; i < ownerBalances.length; i++) {
            uint96 tokens = 1;
            if (i == 0) {
                tokens = 10;
            } else if (i == 1) {
                tokens = 9;
            }

            ownerBalances[i] = OwnerBalance(makeAddr(signerNames[i]), tokens);
        }

        ERC420 erc420 = new ERC420(quorum, ownerBalances);

        uint256 numCases = 1 << ownerBalances.length;
        
        bool[] memory isSigning = new bool[](ownerBalances.length);
        console2.log("cases: %d", numCases);
        for (uint256 num = 0; num < numCases; num++) {
            uint256 bitMask = num;
            uint256 countSigners = 0;
            for (uint256 idx = 0; idx < ownerBalances.length; idx++) {
                if (bitMask % 2 != 0) {
                    isSigning[idx] = true;
                    countSigners++;
                } else {
                    isSigning[idx] = false;
                }
                bitMask /= 2;
            }

            TransactionData memory txn = TransactionData({
                callType: 0,
                expiry: uint64(block.timestamp + 1),
                target: address(this),
                value: 0,
                data: abi.encodeWithSignature("callbackInt(uint256)", num)
            });

            bytes32[] memory sigs = new bytes32[](2 * countSigners);
            uint256 balances = 0;
            uint256 c = 0;
            for (uint256 si = 0; si < ownerBalances.length; si++) {
                if (isSigning[si]) {
                    console2.log("active signer: %s, balance: %d", signerNames[si], ownerBalances[si].balance);
                    (bytes32 r, bytes32 vs) = _sign(signerNames[si], txn);
                    sigs[2*c] = r;
                    sigs[2*c + 1] = vs;
                    c++; // a goddamn classic
                    balances += erc420.balanceOf(ownerBalances[si].owner);
                }
            }

            bool success;
            try erc420.execute(txn, sigs) returns (bool callSuccess, bytes memory res) {
                success = true;
            } catch {
                success = false;
            }

            console2.log("[case #%s] cumulative signing power: %d | %s", num, balances, success);
            console2.log("");
            console2.log("");
            console2.log("");
        }
    }
}
