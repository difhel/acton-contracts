import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "nft-collection.test"
import "../contracts/errors"
import "../contracts/messages"
import "../contracts/types"
import "../wrappers/NftCollection.gen"
import "../wrappers/NftItem.gen"
import "../wrappers/utils"

// Use the wallet's user-friendly address independently of the contract constant.
const WALLET_BURN_ADDRESS = address("UQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJKZ")

fun burnItem(
    item: NftItem,
    owner: address,
    forwardAmount: coins = 0,
    response: address? = null,
): SendResultList {
    return item.sendTransferPayloadInline(
        owner,
        42,
        WALLET_BURN_ADDRESS,
        response,
        null,
        forwardAmount,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );
}

fun expectDeleted(item: NftItem, result: SendResultList, owner: address) {
    expect(result).toHaveSuccessfulTx<AskToChangeOwnership>({ from: owner, to: item.address });
    val tx = result.findTransaction({ from: owner, to: item.address })!;
    expect(tx.endStatus).toEqual(TlbAccountStatus.NonExisting);
    expect(testing.getAccountState(item.address)).toBeNull();
    expect(testing.getAccountBalance(item.address)).toEqual(0);
    expect(result).toHaveTx<ReturnExcessesBack>({
        from: item.address,
        to: owner,
        bounce: false,
        body: ReturnExcessesBack { queryId: 42 }.toCell(),
    });
    val description = tx.description.load();
    expect(description is TlbTransOrd).toBeTrue();
    if (description is TlbTransOrd) {
        expect(description.destroyed).toBeTrue();
    }
}

get fun `test burn: wallet transfer deletes account and refunds storage reserve`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    testing.topUp(item.address, grams("1"));
    val result = burnItem(item, owner.address);
    expectDeleted(item, result, owner.address);
    expect(result).toNotHaveTx({ from: item.address, to: WALLET_BURN_ADDRESS });
    expect(collection.getCollectionData().nextItemIndex).toEqual(1);
    expect(result).toHaveTx<ReturnExcessesBack>({
        from: item.address,
        to: owner.address,
        value: fun(value: coins): bool {
            return value > grams("1");
        },
    });
}

get fun `test burn: referenced payload is forwarded unchanged and response cannot recreate item`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    val payload = beginCell().storeUint(0x12345678, 32).endCell();
    val result = item.sendTransferPayloadInRef(
        owner.address,
        42,
        WALLET_BURN_ADDRESS,
        item.address,
        null,
        1,
        payload,
        { value: grams("0.05"), bounce: true },
    );
    expectDeleted(item, result, owner.address);
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: item.address,
        to: WALLET_BURN_ADDRESS,
        value: 1,
        body: NotificationForNewOwner {
            queryId: 42,
            oldOwnerAddress: owner.address,
            payload: beginCell()
                .storeBool(true)
                .storeRef(payload)
                .toSlice() as RemainingBitsAndRefs,
        }.toCell(),
    });
    expect(result).toNotHaveTx({ from: item.address, to: item.address });
}

get fun `test burn: unsolicited funds at deleted address do not block remint`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val newOwner = testing.treasury("new-owner");
    val item = nftFixture(collection, owner.address);
    expectDeleted(item, burnItem(item, owner.address), owner.address);
    testing.topUp(item.address, grams("0.01"));
    val state = testing.getAccountState(item.address)!;
    expect(state.storage.state is TlbAccountStateUninit).toBeTrue();
    val result = collection.sendDeployNft(
        admin.address,
        43,
        0,
        grams("0.02"),
        { ownerAddress: newOwner.address, content: "0.json" },
        { value: grams("0.05"), bounce: true },
    );
    expect(result).toHaveSuccessfulTx({ from: collection.address, to: item.address });
    expect(item.getNftData().ownerAddress!).toEqual(newOwner.address);
    expect(collection.getCollectionData().nextItemIndex).toEqual(1);
}

get fun `test burn: refund action failure rolls back destruction and notification`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("masterchain-owner", MASTERCHAIN);
    val item = nftFixture(collection, owner.address);
    // Make the refund unaffordable without failing the basechain notification or
    // the compute-phase balance check. This exercises action rollback, not a throw.
    val originalConfig = testing.getConfig();
    var config = originalConfig;
    var prices = config.getMsgForwardPrices(MASTERCHAIN);
    prices.lumpPrice = grams("1") as uint64;
    config.setMsgForwardPrices(prices, MASTERCHAIN);
    expect(testing.setConfig(config)).toBeTrue();
    val result = burnItem(item, owner.address, 1);
    expect(result).toHaveTx<AskToChangeOwnership>({
        from: owner.address,
        to: item.address,
        exitCode: 0,
        actionExitCode: 37,
        aborted: true,
        success: false,
    });
    expect(result).toNotHaveTx<NotificationForNewOwner>({
        from: item.address,
        to: WALLET_BURN_ADDRESS,
    });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
    expect(testing.setConfig(originalConfig)).toBeTrue();
    expectDeleted(item, burnItem(item, owner.address), owner.address);
}

get fun `test burn: forwards wallet notification and refunds owner despite response destination`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val response = testing.treasury("other-response");
    val item = nftFixture(collection, owner.address);
    // Wallets commonly attach 1 nanoton to ownership_assigned.
    val result = burnItem(item, owner.address, 1, response.address);
    expectDeleted(item, result, owner.address);
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: item.address,
        to: WALLET_BURN_ADDRESS,
        value: 1,
        bounce: false,
        body: NotificationForNewOwner {
            queryId: 42,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeBool(false).toSlice() as RemainingBitsAndRefs,
        }.toCell(),
    });
    expect(result).toNotHaveTx({ from: item.address, to: response.address });
}

get fun `test burn: non-owner including collection admin cannot burn`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    val result = burnItem(item, admin.address);
    expect(result).toHaveFailedTx<AskToChangeOwnership>({
        from: admin.address,
        to: item.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test burn: malformed transfer cannot delete item`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    val body = beginCell()
        .storeUint(0x5fcc3d14, 32)
        .storeUint(42, 64)
        .storeAddress(WALLET_BURN_ADDRESS)
        .storeUint(0, 2) // addr_none response destination
        .storeMaybeRef(null)
        .storeCoins(0)
        .endCell();
    val result = item.sendAny(owner.address, body, { value: grams("0.05"), bounce: true });
    expect(result).toHaveFailedTx({
        from: owner.address,
        to: item.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test burn: unaffordable forward amount preserves live item`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    val result = burnItem(item, owner.address, grams("100"));
    expect(result).toHaveFailedTx<AskToChangeOwnership>({
        from: owner.address,
        to: item.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test burn: same index remints at same address with new owner and remains transferable`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val newOwner = testing.treasury("remint-owner");
    val receiver = testing.treasury("remint-receiver");
    val item = nftFixture(collection, owner.address);
    expectDeleted(item, burnItem(item, owner.address), owner.address);

    val result = collection.sendDeployNft(
        admin.address,
        43,
        0,
        grams("0.02"),
        { ownerAddress: newOwner.address, content: "0.json" },
        { value: grams("0.05"), bounce: true },
    );
    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: item.address });
    expect(collection.getNftAddressByIndex(0)).toEqual(item.address);
    expect(collection.getCollectionData().nextItemIndex).toEqual(1);
    val data = item.getNftData();
    expect(data.itemIndex).toEqual(0);
    expect(data.collectionAddress).toEqual(collection.address);
    expect(data.ownerAddress!).toEqual(newOwner.address);
    expect(data.content).toEqual("0.json");

    val oldOwnerBurn = burnItem(item, owner.address);
    expect(oldOwnerBurn).toHaveFailedTx<AskToChangeOwnership>({
        from: owner.address,
        to: item.address,
        exitCode: Errors.NotFromOwner,
    });
    val transfer = item.sendTransferPayloadInline(
        newOwner.address,
        44,
        receiver.address,
        null,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );
    expect(transfer).toHaveSuccessfulTx<AskToChangeOwnership>({
        from: newOwner.address,
        to: item.address,
    });
    expect(item.getNftData().ownerAddress!).toEqual(receiver.address);
    expectDeleted(item, burnItem(item, receiver.address), receiver.address);
}

get fun `test burn: non-admin cannot remint through collection`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    expectDeleted(item, burnItem(item, owner.address), owner.address);
    val result = collection.sendDeployNft(
        owner.address,
        43,
        0,
        grams("0.02"),
        { ownerAddress: owner.address, content: "stolen.json" },
        { value: grams("0.05"), bounce: true },
    );
    expect(result).toHaveFailedTx<DeployNft>({
        from: owner.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(testing.getAccountState(item.address)).toBeNull();
}

get fun `test burn: direct redeployment cannot hijack deleted item`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val attacker = testing.treasury("attacker");
    val item = nftFixture(collection, owner.address);
    expectDeleted(item, burnItem(item, owner.address), owner.address);
    val skeleton = NftItem.fromStorage({ itemIndex: 0, collectionAddress: collection.address });
    expect(skeleton.address).toEqual(item.address);
    val result = net.send(
        attacker.address,
        createMessage({
            dest: { stateInit: skeleton.stateInit! },
            value: grams("0.05"),
            bounce: BounceMode.Only256BitsOfBody,
            body: NftItemInitAtDeployment {
                ownerAddress: attacker.address,
                content: "stolen.json",
            },
        }),
    );
    expect(result).toHaveFailedTx({
        from: attacker.address,
        to: item.address,
        exitCode: Errors.NotFromCollection,
    });
    // A failed unauthorized deployment must not prevent later legitimate initialization.
    val remint = collection.sendDeployNft(
        admin.address,
        43,
        0,
        grams("0.02"),
        { ownerAddress: owner.address, content: "0.json" },
        { value: grams("0.05"), bounce: true },
    );
    expect(remint).toHaveSuccessfulTx({ from: collection.address, to: item.address });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test burn: admin cannot overwrite a live NFT by deploying its index again`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val item = nftFixture(collection, owner.address);
    val result = collection.sendDeployNft(
        admin.address,
        43,
        0,
        grams("0.02"),
        { ownerAddress: admin.address, content: "replacement.json" },
        { value: grams("0.05"), bounce: true },
    );
    expect(result).toHaveTx({ from: collection.address, to: item.address, success: false });
    expect(item.getNftData().ownerAddress!).toEqual(owner.address);
    expect(item.getNftData().content).toEqual("");
    expect(collection.getCollectionData().nextItemIndex).toEqual(1);
}

get fun `test burn: batch can remint burned index and mint next index together`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("burn-owner");
    val newOwner = testing.treasury("batch-owner");
    val item = nftFixture(collection, owner.address);
    expectDeleted(item, burnItem(item, owner.address), owner.address);
    var deployList: map<uint64, BatchDeployDictItem> = [];
    var index = 0;
    repeat (2) {
        deployList.set(
            index,
            {
                attachTonAmount: grams("0.02"),
                initParams: NftItemInitAtDeployment {
                    ownerAddress: newOwner.address,
                    content: "batch.json",
                }.toCell(),
            },
        );
        index += 1;
    }
    val result = collection.sendBatchDeployNfts(
        admin.address,
        43,
        deployList,
        { value: grams("0.1"), bounce: true },
    );
    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: item.address });
    expect(item.getNftData().ownerAddress!).toEqual(newOwner.address);
    val nextItem = NftItem.fromAddress(collection.getNftAddressByIndex(1));
    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: nextItem.address });
    expect(nextItem.getNftData().ownerAddress!).toEqual(newOwner.address);
    expect(collection.getCollectionData().nextItemIndex).toEqual(2);
}
