// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import './SafeMath.sol';
import './IBEP20.sol';
import './SafeBEP20.sol';
import './Ownable.sol';

import './DeeDeeToken.sol';

// MasterChef is the home of the cute DeeDee girl. It can make DEEDEE tokens for her so that she continue messing with Dexter's work.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once DEEDEE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of DEEDEEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accDEEDEEPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accDEEDEEPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. DEEDEEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that DEEDEEs distribution occurs.
        uint256 accDEEDEEPerShare;   // Accumulated DEEDEEs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
    }

    // The DEEDEE TOKEN!
    DeeDee public DEEDEE;
    // Dev address.
    address public devaddr;
    // DEEDEE tokens created per block.
    uint256 public deedeePerBlock;
    // Bonus muliplier for early DEEDEE makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when DEEDEE mining starts.
    uint256 public startBlock;

    // Total locked up rewards
    uint256 public totalLockedUpRewards;
    // Total VENUS in VENUS Pools (can be multiple pools)
    uint256 public totalDEEDEEInPools = 0;

    // Maximum deposit fee rate: 10%
    uint16 public constant MAXIMUM_DEPOSIT_FEE_RATE = 1000;
    // Min Havest interval: 1 hour
    uint256 public MINIMUM_HARVEST_INTERVAL = 3600;
    // Max harvest interval: 14 days.
    uint256 public MAXIMUM_HARVEST_INTERVAL = 14 days;



    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amountHarvest);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        DeeDee _DEEDEE,
        address _devaddr,
        address _feeAddress,
        uint256 _deedeePerBlock,
        uint256 _startBlock
    ) public {
        DEEDEE = _DEEDEE;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        deedeePerBlock = _deedeePerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function remainRewards() external view returns (uint256) {
        return DEEDEE.balanceOf(address(this)).sub(totalDEEDEEInPools);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "add: deposit fee too high");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accDEEDEEPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval : _harvestInterval
        }));
    }

    // Update the given pool's DEEDEE allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "set: deposit fee too high");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending DEEDEEs on frontend.
    function pendingDEEDEE(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accDEEDEEPerShare = pool.accDEEDEEPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 deedeeReward = multiplier.mul(deedeePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accDEEDEEPerShare = accDEEDEEPerShare.add(deedeeReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accDEEDEEPerShare).div(1e12).sub(user.rewardDebt);

        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // View function to calc current Harvest Tax %
    function harvestTax(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        if (block.timestamp >= user.nextHarvestUntil) {
            return 0;
        } else {
            uint256 remainingBlocks = user.nextHarvestUntil.sub(block.timestamp);
            uint256 harvestTaxAmount = remainingBlocks.mul(100).div(pool.harvestInterval);

            if (harvestTaxAmount < 2) {
                return 0;
            } else {
                return harvestTaxAmount;
            }
        }

    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 deedeeReward = multiplier.mul(deedeePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        DEEDEE.mint(devaddr, deedeeReward.div(10));
        DEEDEE.mint(address(this), deedeeReward);
        pool.accDEEDEEPerShare = pool.accDEEDEEPerShare.add(deedeeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for DEEDEE allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingDEEDEE(_pid, _amount);
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if(pool.depositFeeBP > 0){
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);

                if (address(pool.lpToken) == address(DEEDEE)) {
                    totalDEEDEEInPools = totalDEEDEEInPools.add(_amount).sub(depositFee);
                }
            } else {
                user.amount = user.amount.add(_amount);

                if (address(pool.lpToken) == address(DEEDEE)) {
                    totalDEEDEEInPools = totalDEEDEEInPools.add(_amount);
                }
            }
        }
        user.rewardDebt = user.amount.mul(pool.accDEEDEEPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingDEEDEE(_pid, _amount);
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);

            if (address(pool.lpToken) == address(DEEDEE)) {
                totalDEEDEEInPools = totalDEEDEEInPools.sub(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accDEEDEEPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.nextHarvestUntil = 0;
        user.rewardLockedUp = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);

        if (address(pool.lpToken) == address(DEEDEE)) {
            totalDEEDEEInPools = totalDEEDEEInPools.sub(amount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending DEEDEE.
    function payOrLockupPendingDEEDEE(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accDEEDEEPerShare).div(1e12).sub(user.rewardDebt);

        if (pending > 0 || user.rewardLockedUp > 0) {

            if (_amount == 0) { // User wanna harvest

                uint256 totalRewards = pending.add(user.rewardLockedUp);

                //Check Harvest Tax
                uint256 harvestTaxAmount = harvestTax(_pid, msg.sender);
                uint256 taxRewards = totalRewards.mul(harvestTaxAmount).div(100);
                uint256 netRewards = totalRewards.sub(taxRewards);

                // send rewards
                safeDEEDEETransfer(feeAddress, taxRewards);
                safeDEEDEETransfer(msg.sender, netRewards);
                emit Harvest(msg.sender, _pid, netRewards);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

            } else { // User is making another deposit or withdrawal & has some pending

                user.rewardLockedUp = user.rewardLockedUp.add(pending);
                totalLockedUpRewards = totalLockedUpRewards.add(pending);
                emit RewardLockedUp(msg.sender, _pid, pending);

            }

        }

    }

    // Safe DEEDEE transfer function, just in case if rounding error causes pool to not have enough DEEDEEs.
    function safeDEEDEETransfer(address _to, uint256 _amount) internal {
        uint256 deedeeBal = DEEDEE.balanceOf(address(this)).sub(totalDEEDEEInPools);
        if (_amount > deedeeBal) {
            DEEDEE.transfer(_to, deedeeBal);
        } else {
            DEEDEE.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress(address _feeAddress) public{
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _deedeePerBlock) public onlyOwner {
        massUpdatePools();
        deedeePerBlock = _deedeePerBlock;
    }

    // Update start reward block
    function setStartRewardBlock(uint256 _block) public onlyOwner {
        startBlock = _block;
    }

    // Update min harvest interval
    function setMinHarvestInterval(uint256 _min) public onlyOwner {
        MINIMUM_HARVEST_INTERVAL = _min;
    }

    // Update max harvest interval
    function setMaxHarvestInterval(uint256 _max) public onlyOwner {
        MAXIMUM_HARVEST_INTERVAL = _max;
    }
}
