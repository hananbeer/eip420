// SPDX-License-Identifier: Beerware
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {ERC420, TransactionData, OwnerBalance, ExecutionRecord, TxFlag_delegateCall, TxFlag_vaultLock, TxFlag_chainLock} from "../src/ERC420.sol";

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
        TransactionData memory txn,
        ERC420 vault
    ) internal returns (bytes32, bytes32) {
        (address addr, uint256 pk) = makeAddrAndKey(name);
        bytes32 hash = vault.getSigHash(txn);
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

        ERC420 vault = new ERC420(
            "Single Owner Vault",
            "SOV",
            quorum,
            ownerBalances
        );

        TransactionData memory txn = TransactionData({
            flags: 0,
            expiry: uint64(block.timestamp + 1),
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("callback(bytes)", hex"abcd")
        });

        (bytes32 r, bytes32 vs) = _sign(name, txn, vault);

        bytes32[] memory sigs = new bytes32[](2);
        sigs[0] = r;
        sigs[1] = vs;
        vault.execute(txn, sigs);
    }

    function test_multipleOwners() public {
        uint256 quorum = 10;

        // signatures is expected to be sorted by signer address
        // this order was done manually using the helper console log below
        string[4] memory signerNames = [
            "trustee1",
            "main",
            "trustee2",
            "secondary"
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
            // signatures is expected to be sorted by signer address
            // uncomment this to sort manually if you get "signers must have ascending order"
            // console2.log("owner %s = %x", signerNames[i], ownerBalances[i].owner);
        }

        ERC420 vault = new ERC420(
            "Multi Owner Vault",
            "MOV",
            quorum,
            ownerBalances
        );

        uint256 numCases = 1 << ownerBalances.length;

        bool[] memory isSigning = new bool[](ownerBalances.length);
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
                flags: 0,
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
                    console2.log(
                        "active signer: %s, balance: %d",
                        signerNames[si],
                        ownerBalances[si].balance
                    );
                    (bytes32 r, bytes32 vs) = _sign(
                        signerNames[si],
                        txn,
                        vault
                    );
                    sigs[2 * c] = r;
                    sigs[2 * c + 1] = vs;
                    c++; // a goddamn classic
                    balances += vault.balanceOf(ownerBalances[si].owner);
                }
            }

            bool success;
            try vault.execute(txn, sigs) returns (
                bool callSuccess,
                bytes memory res
            ) {
                success = true;
            } catch {
                success = false;
            }

            console2.log(
                "[case #%s] cumulative signing power: %d | %s",
                num,
                balances,
                success
            );
            console2.log("");
            console2.log("");
            console2.log("");

            if (
                vault.getSigningPower(vault.getSigHash(txn), sigs) <
                vault.QUORUM()
            ) {
                require(
                    !success,
                    "multi owners execution succeeded even though quorum was unmet"
                );
            } else {
                require(
                    success,
                    "multi owners have quorum but execution failed"
                );
            }
        }
    }

    function test_vaultLock() public {
        uint256 quorum = 100;

        string memory name = "alice";
        OwnerBalance[] memory ownerBalances = new OwnerBalance[](1);
        ownerBalances[0] = OwnerBalance(makeAddr(name), uint96(quorum));

        ERC420 vault1 = new ERC420(
            "Locked Vault 1",
            "SOV",
            quorum,
            ownerBalances
        );
        ERC420 vault2 = new ERC420(
            "Locked Vault 2",
            "SOV",
            quorum,
            ownerBalances
        );

        TransactionData memory txn = TransactionData({
            flags: TxFlag_vaultLock,
            expiry: uint64(block.timestamp + 1),
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("callback(bytes)", hex"abcd")
        });

        // sign with vault1 but execute on vault2
        (bytes32 r, bytes32 vs) = _sign(name, txn, vault1);

        bytes32[] memory sigs = new bytes32[](2);
        sigs[0] = r;
        sigs[1] = vs;
        try vault2.execute(txn, sigs) {
            revert(
                "execution on locked vault is expected to fail but succeeded"
            );
        } catch {}
    }

    function test_chainLock() public {
        uint256 quorum = 100;

        string memory name = "alice";
        OwnerBalance[] memory ownerBalances = new OwnerBalance[](1);
        ownerBalances[0] = OwnerBalance(makeAddr(name), uint96(quorum));

        ERC420 vault = new ERC420(
            "Chain Locked Vault",
            "CLV",
            quorum,
            ownerBalances
        );

        TransactionData memory txn = TransactionData({
            flags: TxFlag_chainLock,
            expiry: uint64(block.timestamp + 1),
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("callback(bytes)", hex"abcd")
        });

        (bytes32 r, bytes32 vs) = _sign(name, txn, vault);

        bytes32[] memory sigs = new bytes32[](2);
        sigs[0] = r;
        sigs[1] = vs;

        // sign with one chain id but call on a different chain id
        vm.chainId(block.chainid + 1);

        try vault.execute(txn, sigs) {
            revert(
                "execution on chain locked vault is expected to fail but succeeded"
            );
        } catch {}
    }

    function test_delegateCall() public {
        uint256 quorum = 100;

        string memory name = "alice";
        OwnerBalance[] memory ownerBalances = new OwnerBalance[](1);
        ownerBalances[0] = OwnerBalance(makeAddr(name), uint96(quorum));

        ERC420 vault = new ERC420(
            "Single Owner Vault",
            "SOV",
            quorum - 1, // allow transferring 1 token
            ownerBalances
        );

        // impersonate alice and transfer some tokens to fail delegatecall quorum requirements
        vm.prank(makeAddr(name));
        vault.transfer(address(this), 1); // just 1 token

        TransactionData memory txn = TransactionData({
            flags: TxFlag_delegateCall,
            expiry: uint64(block.timestamp + 1),
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("callback(bytes)", hex"abcd")
        });

        (bytes32 r, bytes32 vs) = _sign(name, txn, vault);

        bytes32[] memory sigs = new bytes32[](2);
        sigs[0] = r;
        sigs[1] = vs;
        try vault.execute(txn, sigs) {
            revert(
                "execution of delegatecall is expected to fail without full quorum but succeeded"
            );
        } catch {}
    }
}
