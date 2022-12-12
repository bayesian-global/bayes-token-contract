// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

enum PoolStatus {
    Active,
    Jail
}

enum PoolType {
    small,
    middle,
    large
}

interface IERC1155Burnable {
    function burn(
        address account,
        uint256 id,
        uint256 value
    ) external;
}

interface IERC20Burnable is IERC20 {
    function burnFrom(address account, uint256 amount) external;
}

contract MiningPool is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    uint256 public constant DENOMINATOR = 10000;

    address public immutable token;
    address public card;

    address public payee;
    address public weightPayee;
    address public dao;
    
    uint256 public virtualHashrates;
    uint256 public usersHashrates;
    uint256 public lastUpdateTime;
    
    uint256 public tokenRatio;
    uint256 public hashratesRatio = 10;
 
    uint256 public rewardPerHashrateStored;
    uint256 public startWindowTime;

    mapping(address => User) public users;

    PoolInfo[] public pools;

    EnumerableSet.Bytes32Set private _names;
    
    event UserRewardRatioUpdated(address indexed account,uint256 previousRatio,uint256 newRatio);
    event UserHashratesUpdated(address indexed account,uint256 previous,uint256 newHashRates);
    event HashratesRatioUpdated(uint256 previousRatio,uint256 newRatio);
    event TokenRatioUpdated(uint256 previousRatio,uint256 newRatio);
    event PayeeUpdated(address previousPayee,address newPayee);
    event WeightPayeeUpdated(address previousWeightPayee,address newWeightPayee);
    event DaoUpdated(address previousDao,address newDao);
    event ActivedPool(address indexed account, uint256 poolIndex,uint256 tokenId);
    event OwnershipPoolTransferred(uint256 poolIndex,address previousAccount,address newAccount);
    event PoolNameUpdated(address indexed account, uint256 poolIndex, bytes32 name);
    event PoolStatusUpdated(uint8 previousStatus,uint8 newStatus);
    event Staked(address indexed account,uint256 poolIndex,uint256 amount,uint256 hashrates,uint256 fule);
    event Claimed(address indexed account, uint256 poolIndex, uint256 amount);

    struct PoolInfo {
        address owner;
        bytes32 name;
        uint8 status;
        uint8 poolType;
        uint256 hashrate;
        uint256 userCount;
    }

    struct User {
        uint256 poolIndex;
        uint256 hashrate;
        uint256 balance;
        uint256 reward;
        uint256 lastBalance;
        uint256 lastRewardPerHashrate;
        uint256 lastUpdateTime;
        uint256 rewardRatio;
        bool externalUpdate;
        bool staked;
    }
   
    modifier updateReward(address account) {
        rewardPerHashrateStored = _rewardPerHashrate();
        lastUpdateTime = block.timestamp;

        if (account != address(0)) {
            User storage user = users[account];
            user.reward = earned(account);
            user.balance -= expensed(account) > user.balance
                ? user.balance
                : expensed(account);
            user.lastRewardPerHashrate = rewardPerHashrateStored;
            user.lastUpdateTime = block.timestamp;
        }
        _;
    }

   constructor(
        address token_,
        address card_,
        address payee_,
        address weightPayee_,
        address dao_
    ) {
        require(
            token_ != address(0) &&
            card_ != address(0) &&
            payee_ != address(0) &&
            weightPayee_ != address(0) &&
            dao_ != address(0),
            "Invalid arguments"
        );

        token = token_;
        card = card_;
        weightPayee = weightPayee_;
        payee = payee_;
        dao = dao_;
        startWindowTime = block.timestamp;
    }

    function contains(bytes32 name) public view returns (bool) {
        return _names.contains(name);
    }

    function periodFinish(address account) public view returns (uint256) {
        User memory user = users[account];
        if (user.hashrate == 0) {
            return user.lastUpdateTime;
        }
        return user.lastUpdateTime + (user.balance * totalHashrates() * DENOMINATOR) / ((rewardPerSecond() * user.hashrate * tokenRatio));
    }

    function royaltyRate(uint256 poolIndex) private view returns (uint256) {
        PoolInfo memory pool = pools[poolIndex];
        if (pool.poolType == uint8(PoolType.small)) {
            return pool.hashrate >= 100 * 1e18 ? 11 : 9;
        }
        if (pool.poolType == uint8(PoolType.middle)) {
            return pool.hashrate >= 1000 * 1e18 ? 17 : 15;
        }
        return pool.hashrate >= 10000 * 1e18 ? 23 : 21;
    }
    
    function earned(address account) public view returns (uint256) {
        User memory user = users[account];
        uint256 rewardDuration = Math.min(
            block.timestamp,
            periodFinish(account)
        ) - user.lastUpdateTime;

        uint256 ratio = user.rewardRatio == 0 ? DENOMINATOR : user.rewardRatio;

        if (rewardDuration == 0) {
            return user.reward.mul(ratio).div(DENOMINATOR);
        }
 
        uint256 userReward = ((((user.hashrate *
                (_rewardPerHashrate() - user.lastRewardPerHashrate)) / 1e18) *
                rewardDuration) /
            (block.timestamp - user.lastUpdateTime)) * DENOMINATOR / tokenRatio;

        uint256 reward = user.reward + userReward.mul(ratio).div(DENOMINATOR);
        return reward;    
    }

    function expensed(address account) public view returns (uint256) {
        User memory user = users[account];

        uint256 rewardDuration = Math.min(
            block.timestamp - user.lastUpdateTime,
            periodFinish(account) - user.lastUpdateTime
        );
        if (rewardDuration == 0) {
            return 0;
        }

        uint256 userExpensedPerSec = (rewardPerSecond() * user.hashrate / totalHashrates()) * tokenRatio / DENOMINATOR;
        return (rewardDuration + 1) * userExpensedPerSec > user.balance ? 
            user.balance : rewardDuration * userExpensedPerSec;
    }

    function rewardPerSecond() public view returns (uint256) {
         if (block.timestamp <= startWindowTime * 4) {
            return 9961916000000000000;
         }
         if (block.timestamp <= startWindowTime * 8) {
            return 6973341000000000000;
         }
         if (block.timestamp <= startWindowTime * 12) {
            return 4233814000000000000;
         }
         return 0;
    }

    function totalHashrates() public view returns (uint256) {
        return virtualHashrates + usersHashrates;
    }

    function userFuleAndHashrates(address account,uint256 amount) public view returns (uint256 fule,uint256 hashrate) {
        require(amount >= 100 * 1e18,"insufficient amount");
        User memory user = users[account];
        fule = amount.mul(tokenRatio).div(DENOMINATOR);
        if (user.balance > 0) {
            uint256 validFule = fule > (user.lastBalance - user.balance).div(2) ?
                fule - (user.lastBalance - user.balance).div(2) : 0;
            hashrate = validFule.mul(hashratesRatio).div(DENOMINATOR);
        }else {
            hashrate = fule.mul(hashratesRatio).div(DENOMINATOR);
        }
        fule = fule.mul(2);
    }

    function setPayee(address newPayee) external onlyOwner {
        require(newPayee != address(0), "address should not be zero");
        address previousPayee = payee;
        payee = newPayee;
        emit PayeeUpdated(previousPayee, newPayee);
    }

    function setWeightPayee(address newWeightPayee) external onlyOwner {
        require(newWeightPayee != address(0), "address should not be zero");
        address previousWeightPayee = weightPayee;
        weightPayee = newWeightPayee;
        emit WeightPayeeUpdated(previousWeightPayee, newWeightPayee);
    }

    function setDao(address newDao) external onlyOwner {
        require(newDao != address(0), "address should not be zero");
        address previousDao = dao;
        dao = newDao;
        emit DaoUpdated(previousDao, newDao);
    }
    
    function setTokenRatio(uint256 ratio) external onlyOwner {
        uint256 previousRatio = tokenRatio;
        tokenRatio = ratio;
        lastUpdateTime = block.timestamp;
        rewardPerHashrateStored = _rewardPerHashrate();
        emit TokenRatioUpdated(previousRatio, tokenRatio);
    }
    
    function setPoolStatus(uint256 poolIndex,uint8 status) external nonReentrant onlyOwner {
        uint8 previousStatus = pools[poolIndex].status;
        pools[poolIndex].status = status;
        emit PoolStatusUpdated(previousStatus,status);
    }

    function setPoolName(uint256 poolIndex,bytes32 name) external nonReentrant {
        require(pools[poolIndex].owner == _msgSender(),"not ownner");
        require(_names.add(name),"already exits");

        _names.remove(pools[poolIndex].name);
        pools[poolIndex].name = name;
        
        IERC20(token).safeTransferFrom(_msgSender(),address(this),uint256(10).mul(tokenRatio).div(DENOMINATOR));
        emit PoolNameUpdated(_msgSender(),poolIndex,name);
    }

    function setHashratesRatio(uint256 ratio) external onlyOwner {
        uint256 previousRatio = hashratesRatio;
        hashratesRatio = ratio;
        emit HashratesRatioUpdated(previousRatio, hashratesRatio);
    }

    function setHashrates(uint256 hashrates) external onlyOwner {
        virtualHashrates = hashrates;
    }

    function setUserHashrates(address account,uint256 hashrates) external onlyOwner {
        uint256 previous = users[account].hashrate;
        users[account].hashrate = hashrates;
        emit UserHashratesUpdated(account,previous,hashrates);
    }

    function setUserRewardRatio(address account,uint256 ratio) external onlyOwner {
        uint256 previous = users[account].rewardRatio;
        users[account].hashrate = ratio;
        emit UserRewardRatioUpdated(account,previous,ratio);
    }

    function updateUserInfo(address account) external nonReentrant onlyOwner updateReward(account) {
        User storage user = users[_msgSender()];
        if(user.balance == 0) {
            uint256 hashrate = user.hashrate;
            user.hashrate = 0;
            pools[user.poolIndex].hashrate -= hashrate;
            pools[user.poolIndex].userCount -= 1;
            usersHashrates -= hashrate;
            user.staked = false;
            user.externalUpdate = true;
        }
    }

    function activePool(bytes32 name,uint256 tokenId) external nonReentrant {
        require(!contains(name),"already exit name");
        _names.add(name);
        
        pools.push(PoolInfo({
            owner : _msgSender(),
            name : name,
            status : uint8(PoolStatus.Active),
            poolType : uint8(tokenId),
            hashrate : 0,
            userCount : 0
        }));
        
        IERC1155Burnable(card).burn(_msgSender(),tokenId,1);
        emit ActivedPool(_msgSender(),pools.length - 1,tokenId);
    } 

    function poolTransferOwnership(uint256 poolIndex,address account) external onlyOwner {
        address previous = pools[poolIndex].owner;
        pools[poolIndex].owner = account;
        emit OwnershipPoolTransferred(poolIndex,previous,account);
    }

    function stake(uint256 amount,uint256 poolIndex) external nonReentrant updateReward(_msgSender()) {
        require(amount >= 100 * 1e18,"insufficient stake amount");
  
        User memory user = users[_msgSender()];
        require(!user.staked || user.poolIndex == poolIndex,"already stake another pool");

        (uint256 fule,uint256 hashrate) = userFuleAndHashrates(_msgSender(),amount);
        user.hashrate += hashrate;
        user.balance += fule;
        user.lastBalance = user.balance;
        user.poolIndex = poolIndex;
        
        _executeTransferFrom(_msgSender(),amount,poolIndex);

        PoolInfo storage pool = pools[poolIndex];
        pool.hashrate += hashrate;
        pool.userCount += user.staked ? 0 : 1;
        user.staked = true;

        usersHashrates += hashrate;

        users[_msgSender()] = user;
        
        emit Staked(_msgSender(),poolIndex,amount,hashrate,fule);
    }

    function claimRewards() external nonReentrant updateReward(_msgSender()) {
        User storage user = users[_msgSender()];
        uint256 reward = user.reward;
        if(reward > 0) {
            IERC20(token).safeTransfer(_msgSender(),reward);
            user.reward = 0;
        }

        emit Claimed(_msgSender(),user.poolIndex,reward);

        if(user.balance == 0 && !user.externalUpdate) {
            uint256 hashrate = user.hashrate;
            pools[user.poolIndex].hashrate -= hashrate;
            pools[user.poolIndex].userCount -= 1;
            usersHashrates -= hashrate;
            delete users[_msgSender()];
        }
    }
    
    function _executeTransferFrom(address from, uint256 amount,uint256 poolIndex) private {
        uint256 payeeAmount = amount.mul(6).div(100);
        uint256 weightPayeeAmount = amount.mul(1).div(100);
        uint256 burnAmount = amount.mul(70).div(100);
        uint256 reward = amount.mul(royaltyRate(poolIndex)).div(100);

        IERC20Burnable(token).burnFrom(from,burnAmount);
        IERC20(token).safeTransferFrom(from,payee,payeeAmount);
        IERC20(token).safeTransferFrom(from,weightPayee,weightPayeeAmount);
        IERC20(token).safeTransferFrom(from,pools[poolIndex].owner,reward);
        IERC20(token).safeTransferFrom(from,dao,
            amount - payeeAmount - weightPayeeAmount - burnAmount - reward
        );
    }

    function _rewardPerHashrate() private view returns (uint256) {
        if (usersHashrates == 0) {
            return rewardPerHashrateStored;
        }

        return
            rewardPerHashrateStored +
            (((block.timestamp - lastUpdateTime) * rewardPerSecond() * 1e18 * tokenRatio) /
                (totalHashrates() * DENOMINATOR));
    }
}