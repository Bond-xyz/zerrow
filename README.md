# Zerrow Lending Protocol

## Rewards Model

Bond rewards are not distributed by the Zerrow lending contracts.

Current Bond deployments use the separate `bond-rewards` system for reward
accrual, review, root publication, proofs, and wallet claims. Users claim
rewards from the configured Merkle or URD reward distributor contracts managed
by `bond-rewards`, not from Zerrow's `rewardContract` address.

The `rewardContract` field in this repository is a legacy Zerrow compatibility
hook. It is only expected to implement `iRewardMini`:

- `factoryUsedRegister(address token, uint256 type)`
- `recordUpdate(address user, uint256 value)`

This hook is not a reward distributor, not a claim contract, and not canonical
reward state for Bond. Do not fund it, do not present it as a user-facing reward
contract, and do not use it as an input to Bond reward accounting.

The 0G mainnet beta deployment used a mock compatibility hook at
`0x973Ea4496Ea7C127d2bbF0F378ca12510d3056F4`. Treat that address as a legacy
bookkeeping hook only.

### Runtime Compatibility

The legacy hook still exists in deployed Zerrow contracts:

- `coinFactory` requires a nonzero reward hook when creating deposit and loan
  coins.
- newly created deposit and loan coins store that hook address.
- deposit and loan coin mint/burn paths try to call `recordUpdate`.

Those calls are compatibility behavior for the original Zerrow design. They do
not replace `bond-rewards` and should not be used to calculate claimable rewards.

If a future deployment keeps the current contracts, use a verified no-op
`iRewardMini` implementation or the mock only as a compatibility address. Do not
set a Merkle distributor or URD contract as `rewardContract`; those contracts do
not implement `iRewardMini`.

Removing the hook entirely should be treated as a protocol upgrade because it
changes factory and deposit/loan coin runtime behavior.
