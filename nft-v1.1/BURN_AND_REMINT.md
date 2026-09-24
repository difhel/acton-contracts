# NFT burn and re-mint fork

This fork extends the Tolk NFT item for collections that want to redeploy deleted
items at the same index and contract address. The collection contract, storage
layouts and message opcodes remain unchanged. The item code changes, so a newly deployed collection
must use this fork's compiled `NftItem` code. Existing non-upgradeable NFTs cannot
gain this behavior.

## Burn through a wallet

The current NFT owner sends the ordinary TEP-62 `transfer` (`0x5fcc3d14`) with
`new_owner = 0:0000000000000000000000000000000000000000000000000000000000000000`.
Its non-bounceable user-friendly form is `UQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJKZ`.

The item validates ownership, the transfer payload, workchains and funding as
before. If `forward_ton_amount` is nonzero, it sends the usual `ownership_assigned`
notification to the burn address. It then sends all remaining TON, including the
storage reserve, to the **previous owner** in an `excesses` message carrying the
original `query_id`. Send mode `128 | 32` drains the balance and deletes the account.
The refund is non-bounceable and action errors are not ignored.

For burns, `response_destination` does not redirect the refund: it always goes to
the authenticated owner. Ordinary transfers retain the upstream behavior. Transfers
to other dead-looking addresses do not trigger destruction. This extension changes
the semantics of transferring to the basechain zero address; it is not a standard
NFT burn opcode.

## Re-mint an index

After confirming the successful destruction transaction, the collection admin can
send the existing `DeployNft` message (opcode `1`) with the burned `itemIndex`, new
`ownerAddress`, content and deployment funding. Batch deployment (opcode `2`) also
accepts previously issued indexes. `nextItemIndex` is a high-water mark, not the
number of currently live items; burning or re-minting an old index does not change it.

The **NFT contract address stays the same** because its initial state depends on
the collection address, item index and item code. The new owner's wallet address
can differ. An existing live NFT cannot be overwritten this way. Only the collection
admin may request deployment, and only the collection may initialize an item, even
if someone else submits its publicly available StateInit.

Burn is intentionally reversible by the collection admin through re-minting. Wallets
and indexers may cache the old owner or metadata, so this lifecycle needs integration
testing in each client. This fork has local emulator tests; it has not been
independently audited or deployed by this change.

## Validation

Use Acton **1.2.0**, pinned in `Acton.toml`, from the repository root:

```sh
acton build
acton fmt --check
acton check
acton test nft-v1.1/tests
```

`tests/burn-and-remint.test.tolk` covers actual account deletion, refunds, wallet
notifications, authorization, malformed/underfunded transfers, same-address re-mint,
post-mint transfers, batch re-mint and attempts to overwrite or hijack items. It also
checks referenced payloads, unsolicited funds at a deleted address, and rollback of
both destruction and notification when the refund fails in the action phase.

Source files: [`contracts/NftItem.tolk`](contracts/NftItem.tolk) and
[`tests/burn-and-remint.test.tolk`](tests/burn-and-remint.test.tolk).
