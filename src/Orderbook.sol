// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
// import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./NonceManager.sol";
import "./lib/OrderVerifier.sol";
import {OrderStructs} from "./lib/OrderStructs.sol";
import {OrderType} from "./enums/OrderType.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {TransferManager} from "./TransferManager.sol";
import {ChainIdInvalid, NoncesInvalid} from "./errors/GlobalErrors.sol";

contract Orderbook is NonceManager, StrategyManager, TransferManager {
    using OrderVerifier for OrderStructs.Maker;

    uint immutable chainId;
    string constant EIP712_DOMAIN_TYPE =
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

    // hash to prevent signature collision
    bytes32 public immutable DOMAIN_SEPARATOR =
        keccak256(
            abi.encode(
                keccak256(abi.encodePacked(EIP712_DOMAIN_TYPE)),
                keccak256(bytes("Orderbook-v1")),
                keccak256(bytes("4")),
                block.chainid,
                address(this) // verifyingContract
            )
        );

    uint256 immutable CHAIN_ID = block.chainid;

    constructor() StrategyManager(msg.sender) TransferManager() {
        chainId = block.chainid;
    }

    function fulfillMakerOrder(
        OrderStructs.Taker calldata takerOrder,
        OrderStructs.Maker calldata makerOrder,
        bytes calldata makerSignature
    ) public {
        bytes32 orderHash = makerOrder.hash();

        address currency = makerOrder.currency;
        require(isCurrencyAllowed[currency], "Currency is not allowed");

        bool result = _computeDigestAndVerify(
            makerOrder.hash(),
            makerSignature,
            makerOrder.signer
        );

        require(result, "Signature of the order is invalid");

        // Verify nonces
        address signer = makerOrder.signer;
        {
            bytes32 userOrderNonceStatus = userOrderNonce[signer][
                makerOrder.orderNonce
            ];

            if (
                // @todo : add the checking about the nonce of the subset
                // userBidAskNonces[signer].askNonce != makerAsk.globalNonce ||
                // userSubsetNonce[signer][makerAsk.subsetNonce] ||

                // if the userOrderNonceStatus is not 0, it means that the order has been fulfilled or cancelled
                (userOrderNonceStatus != bytes32(0) &&
                    userOrderNonceStatus != orderHash)
            ) {
                revert NoncesInvalid();
            }
        }

        (
            uint256[] memory itemIds,
            uint256[] memory amounts,
            address takerRecipient,
            bool isNonceInvalidated
        ) = _executionForTakerOrder(takerOrder, makerOrder, msg.sender);

        _executeTransferNFT(msg.sender, makerOrder, itemIds, amounts);
        _executeTransferERC20(msg.sender, makerOrder);

        // Update the nonce of order maker/signer
        userOrderNonce[signer][makerOrder.orderNonce] = (
            isNonceInvalidated ? MAGIC_VALUE_ORDER_NONCE_EXECUTED : orderHash
        );
    }

    function _executionForTakerOrder(
        OrderStructs.Taker calldata takerOrder,
        OrderStructs.Maker calldata makerOrder,
        address sender
    )
        internal
        returns (
            uint256[] memory itemIds,
            uint256[] memory amounts,
            address recipient,
            bool isNonceInvalidated
        )
    {
        uint256 price;

        // Verify Order timestamp
        makerOrder._verifyOrderTimestampValidity(
            makerOrder.startTime,
            makerOrder.endTime
        );

        // If it's a normal transaction
        if (makerOrder.strategyId == 0) {
            makerOrder._verifyItemIdsAndAmountsEqualLengthsAndValidAmounts(
                makerOrder.amounts,
                makerOrder.itemIds
            );
            (price, itemIds, amounts) = (
                makerOrder.price,
                makerOrder.itemIds,
                makerOrder.amounts
            );
            isNonceInvalidated = true;
        }

        // @todo set information for strategie/// @notice Explain to an end user what this does

        // Bid --> token (or fee if any) recipient is the recipient in the taker order or `msg.sender`
        // Ask --> token (or fee if any) recipient is the signer of the maker order
        if (makerOrder.orderType == OrderType.Bid) {
            recipient = takerOrder.recipient == address(0)
                ? sender
                : takerOrder.recipient;
        } else {
            // makerOrder.orderType == OrderType.Ask
            recipient = makerOrder.signer;
        }
    }

    /**
     * @notice This function is internal and used to transfer NFTs.
     * @dev the recipient and sender are decided by the order type.
     * @param sender msg.sender
     * @param makerOrder OrderStructs.Maker
     * @param itemIds the item ids of the NFT to transfer
     * @param amounts the amounts of the NFT to transfer
     */
    function _executeTransferNFT(
        address sender,
        OrderStructs.Maker memory makerOrder,
        uint256[] memory itemIds,
        uint256[] memory amounts
    ) internal {
        if (makerOrder.orderType == OrderType.Bid) {
            transferOrderNFT(
                sender,
                makerOrder.signer,
                itemIds,
                amounts,
                makerOrder.collectionType,
                makerOrder.collection
            );
        } else {
            // makerOrder.orderType == OrderType.Ask
            transferOrderNFT(
                makerOrder.signer,
                sender,
                itemIds,
                amounts,
                makerOrder.collectionType,
                makerOrder.collection
            );
        }
    }

    function _executeTransferERC20(
        address sender,
        OrderStructs.Maker memory makerOrder
    ) internal {
        if (makerOrder.orderType == OrderType.Bid) {
            transferOrderERC20(
                makerOrder.signer,
                sender,
                makerOrder.price,
                makerOrder.currency
            );
        } else {
            // makerOrder.orderType == OrderType.Ask
            transferOrderERC20(
                sender,
                makerOrder.signer,
                makerOrder.price,
                makerOrder.currency
            );
        }
    }

    /**
     * @notice This function is private and used to verify the chain id, compute the digest, and verify the signature.
     * @dev If chainId is not equal to the cached chain id, it would revert.
     * @param computedHash Hash of order (maker bid or maker ask) or merkle root
     * @param makerSignature Signature of the maker
     * @param signer Signer address
     */
    function _computeDigestAndVerify(
        bytes32 computedHash,
        bytes calldata makerSignature,
        address signer
    ) internal returns (bool) {
        if (chainId == block.chainid) {
            // \x19\x01 is the standard encoding prefix
            return
                OrderVerifier.verify(
                    keccak256(
                        abi.encodePacked(
                            "\x19\x01",
                            DOMAIN_SEPARATOR,
                            computedHash
                        )
                    ),
                    signer,
                    makerSignature
                );
        } else {
            revert ChainIdInvalid(block.chainid);
        }
    }

    function verifyOrderSignature(
        bytes32 computedHash,
        bytes calldata makerSignature,
        address signer
    ) public returns (bool) {
        return _computeDigestAndVerify(computedHash, makerSignature, signer);
    }

    function cancelOrderNonces(uint256[] calldata orderNonces) external {
        _cancelOrderNonces(orderNonces);
    }
}
