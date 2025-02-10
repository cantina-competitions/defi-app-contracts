# Defi-app-contracts

This repository uses [foundry](https://book.getfoundry.sh/) and [bun](https://bun.sh/).

## DefiApp Staking Mechanics

**Goals**

- Create DEX liquidity for the $HOME token and progressively increase the $HOME token liquidity while distributing ownership of DeFi App.
- Promote swapping volume within DefiApp
- Promote increase of Total Value Locked (TVL) for DefiApp partner DeFi protocols.
- Future Goal: Implement bribing-voting mechanics that allow for boosting, which can incentivize swapping a specific coin(s) or deposits into specific partner DeFi protocol(s).
- Distribute value to aligned $HOME token holders.

## Staking Mechanics Flywheel Diagram
![DefiApp Flywheel](image.png)

## Core functionality

**Actor: User**

Methods:  

- `DefiAppStaker.stake(...)`: allows a user to stake liquidity provision tokens (lp) in the staker contract. Each call create a "lock".
- `DLockZap.zap(...)`: allows a user to "zap" tokens directly into the the staker contract. Intermediary logic handles the lp-ing.
- `DefiAppStaker.claimRewards(...)` or `DefiAppStaker.claimAll(...)`: allows a user to claim any earned rewards distributed to stakers.
- `DefiAppStaker.relockExpiredLocks(...)`: allows a user to relock an expired "lock".
- `DefiAppStaker.withdrawExpiredLocks(...)`: allows a user to withdraw an expired "lock" and receive the lp token back.
- `DefiAppHomeCenter.claim(...)`: allows a user to claim emission tokens for a specific epoch with option to directly stake.
- `DefiAppHomeCenter.claimMulti(...)`: allows a user to claim emission tokens for multiple epochs with option to directly stake.

**Actor: Admin**  (for all purpose consider Admin a multisig with various signers and an intermediary timelock to execute txs)

- `DLockZap.setMfd(...)`: Sets reference to the active DefiAppStaker.sol contract.
- `DLockZap.setPoolHelper(...)`: Sets reference to the VolatileAMMPoolHelper.sol that helps interfacing with Aerodrome pool and gauge.
- `DefiAppStaker.setHomeCenter(...)`: Sets reference to the DefiAppHomeCenter.sol
- `DefiAppStaker.setGauge(...)`: Sets reference to the DefiAppHomeCenter.sol
- `DefiAppStaker.setDefaultLockIndex(...)`: Sets the standard lock durations available
- `DefiAppStaker.setRewardDistributors(...)`: Sets the address(es) allowed to add and remove rewards to the DefiAppStaker.sol contract. Rewards are those to be distributed to stakers.
- `DefiAppStaker.setRewardStreamParams(...)`: Sets the parameters for streaming rewards to stakers.
- `DefiAppStaker.setOperationExpenses(...)`: Sets the address that receives and the percentage of rewards dedicated to operational expenses.
- `DefiAppHomeCenter.setDefaultRps(...)`: Sets the rate at which emission token is distributed in the epoch.
- `DefiAppHomeCenter.setDefaultEpochDuration(...)`: Sets the time length of an epoch. Only affecting the upcoming epoch. setVoting(...): Sets voting is active when features gets built and enabled.
- `DefiAppHomeCenter.setMintingActive(...)`: Configuration param that indicates the DefiAppHomeCenter.sol contract that emission token is distributed by minting. 
